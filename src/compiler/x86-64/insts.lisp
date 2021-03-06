;;;; that part of the description of the x86-64 instruction set
;;;; which can live on the cross-compilation host

;;;; This software is part of the SBCL system. See the README file for
;;;; more information.
;;;;
;;;; This software is derived from the CMU CL system, which was
;;;; written at Carnegie Mellon University and released into the
;;;; public domain. The software is in the public domain and is
;;;; provided with absolutely no warranty. See the COPYING and CREDITS
;;;; files for more information.

(in-package "SB!X86-64-ASM")

(eval-when (:compile-toplevel :load-toplevel :execute)
  ;; Imports from this package into SB-VM
  (import '(conditional-opcode
            plausible-signed-imm32-operand-p
            register-p gpr-p xmm-register-p
            ea-p sized-ea ea-base ea-index
            make-ea ea-disp rip-relative-ea) "SB!VM")
  ;; Imports from SB-VM into this package
  (import '(sb!vm::frame-byte-offset sb!vm::rip-tn sb!vm::rbp-tn
            sb!vm::registers sb!vm::float-registers sb!vm::stack))) ; SB names

;;; This type is used mostly in disassembly and represents legacy
;;; registers only. R8-R15 are handled separately.
(deftype reg () '(unsigned-byte 3))

;;; This includes legacy registers and R8-R15.
(deftype full-reg () '(unsigned-byte 4))

;;; The XMM registers XMM0 - XMM15.
(deftype xmmreg () '(unsigned-byte 4))

;;; Default word size for the chip: if the operand size /= :dword
;;; we need to output #x66 (or REX) prefix
(defconstant +default-operand-size+ :dword)

;;; The default address size for the chip. It could be overwritten
;;; to :dword with a #x67 prefix, but this is never needed by SBCL
;;; and thus not supported by this assembler/disassembler.
(defconstant +default-address-size+ :qword)

;;; The printers for registers, memory references and immediates need to
;;; take into account the width bit in the instruction, whether a #x66
;;; or a REX prefix was issued, and the contents of the REX prefix.
;;; This is implemented using prefilters to put flags into the slot
;;; INST-PROPERTIES of the DSTATE.  These flags are the following
;;; symbols:
;;;
;;; OPERAND-SIZE-8   The width bit was zero
;;; OPERAND-SIZE-16  The "operand size override" prefix (#x66) was found
;;; REX              A REX prefix was found
;;; REX-W            A REX prefix with the "operand width" bit set was
;;;                  found
;;; REX-R            A REX prefix with the "register" bit set was found
;;; REX-X            A REX prefix with the "index" bit set was found
;;; REX-B            A REX prefix with the "base" bit set was found
(defconstant +allow-qword-imm+ #b1000000000)
(defconstant +imm-size-8+      #b0100000000)
(defconstant +operand-size-8+  #b0010000000)
(defconstant +operand-size-16+ #b0001000000)
(defconstant +fs-segment+      #b0000100000)
(defconstant +rex+             #b0000010000)
;;; The next 4 exactly correspond to the bits in the REX prefix itself,
;;; to avoid unpacking and stuffing into inst-properties one at a time.
(defconstant +rex-w+           #b1000)
(defconstant +rex-r+           #b0100)
(defconstant +rex-x+           #b0010)
(defconstant +rex-b+           #b0001)

(defun size-nbyte (size)
  (ecase size
    (:byte  1)
    (:word  2)
    (:dword 4)
    (:qword 8)
    (:oword 16)))

;;; If chopping IMM to 32 bits and sign-extending is equal to the original value,
;;; return the signed result, which the CPU will always extend to 64 bits.
;;; Notably this allows MOST-POSITIVE-WORD to be an immediate constant.
;;; Only use this if the actual operand size is 64 bits, because it will lie to you
;;; if you pass in #xfffffffffffffffc but are operating on a :dword - it returns
;;; a small negative, which encodes to a dword.  Apparently the system assembler
;;; considers this a "feature", and merely truncates, though it does warn.
(defun plausible-signed-imm32-operand-p (imm)
  (typecase imm
    ((signed-byte 32) imm)
    ;; Alternatively, the lower bound #xFFFFFFFF80000000 could
    ;; be spelled as (MASK-FIELD (BYTE 33 31) -1)
    ((integer #.(- (expt 2 64) (expt 2 31)) #.most-positive-word)
     (sb!c::mask-signed-field 32 imm))
    (t nil)))
;;; Like above but for 8 bit signed immediate operands. In this case we need
;;; to know the operand size, because, for example #xffcf is a signed imm8
;;; if the operand size is :word, but it is not if the operand size is larger.
(defun plausible-signed-imm8-operand-p (imm operand-size)
  (cond ((typep imm '(signed-byte 8))
         imm)
        ((eq operand-size :qword)
         ;; Try the imm32 test, and if the result is (signed-byte 8),
         ;; then return it, otherwise return NIL.
         (let ((imm (plausible-signed-imm32-operand-p imm)))
           (when (typep imm '(signed-byte 8))
             imm)))
        (t
         (when (case operand-size
                 (:word (typep imm '(integer #xFF80 #xFFFF)))
                 (:dword (typep imm '(integer #xFFFFFF80 #xFFFFFFFF))))
           (sb!c::mask-signed-field 8 imm)))))

;;;; disassembler argument types

;;; Used to capture the lower four bits of the REX prefix all at once ...
(define-arg-type wrxb
  :prefilter (lambda (dstate value)
               (dstate-setprop dstate (logior +rex+ (logand value #b1111)))
               value))
;;; ... or individually (not needed for REX.R and REX.X).
;;; They are always used together, so only the first one sets the REX property.
(define-arg-type rex-w
  :prefilter  (lambda (dstate value)
                (dstate-setprop dstate (logior +rex+ (if (plusp value) +rex-w+ 0)))))
(define-arg-type rex-b
  :prefilter (lambda (dstate value)
               (dstate-setprop dstate (if (plusp value) +rex-b+ 0))))

(define-arg-type width
  :prefilter #'prefilter-width
  :printer (lambda (value stream dstate)
             (declare (ignore value))
             (princ (schar (symbol-name (inst-operand-size dstate)) 0)
                    stream)))

;;; Used to capture the effect of the #x66 operand size override prefix.
(define-arg-type x66
  :prefilter (lambda (dstate junk)
               (declare (ignore junk))
               (dstate-setprop dstate +operand-size-16+)))

;;; Find the Lisp object, if any, called by a "CALL rel32offs"
;;; instruction format and add it as an end-of-line comment,
;;; but not on the host, since NOTE is in target-disassem.
#!+(and immobile-space (not (host-feature sb-xc-host)))
(defun maybe-note-lisp-callee (value dstate)
  (awhen (sb!vm::find-called-object value)
    (note (lambda (stream) (princ it stream)) dstate)))

(define-arg-type displacement
  :sign-extend t
  :use-label (lambda (value dstate) (+ (dstate-next-addr dstate) value))
  :printer (lambda (value stream dstate)
             (or #!+immobile-space
                 (and (integerp value) (maybe-note-lisp-callee value dstate))
                 (maybe-note-assembler-routine value nil dstate))
             (print-label value stream dstate)))

(define-arg-type accum
  :printer (lambda (value stream dstate)
             (declare (ignore value)
                      (type stream stream)
                      (type disassem-state dstate))
             (print-reg 0 stream dstate)))

(define-arg-type reg
  :prefilter #'prefilter-reg-r
  :printer #'print-reg)

(define-arg-type reg-b
  :prefilter #'prefilter-reg-b
  :printer #'print-reg)

(define-arg-type reg-b-default-qword
  :prefilter #'prefilter-reg-b
  :printer #'print-reg-default-qword)

(define-arg-type imm-addr
  ;; imm-addr is used only with opcodes #xA0 through #xA3 which take a 64-bit
  ;; address unless overridden to 32-bit by the #x67 prefix that we don't parse.
  ;; i.e. we don't have (INST-ADDR-SIZE DSTATE), so always take it to be 64 bits.
  :prefilter (lambda (dstate) (read-suffix 64 dstate))
  :printer #'print-label)

;;; Normally, immediate values for an operand size of :qword are of size
;;; :dword and are sign-extended to 64 bits.
;;; The exception is that opcode group 0xB8 .. 0xBF allows a :qword immediate.
(define-arg-type signed-imm-data
  :prefilter (lambda (dstate &aux (width (inst-operand-size dstate)))
               (when (and (not (dstate-getprop dstate +allow-qword-imm+))
                          (eq width :qword))
                 (setf width :dword))
               (read-signed-suffix (* (size-nbyte width) n-byte-bits) dstate))
  :printer (lambda (value stream dstate)
             (if (maybe-note-static-symbol value dstate)
                 (princ16 value stream)
                 (princ value stream))))

(define-arg-type signed-imm-data/asm-routine
  :type 'signed-imm-data
  :printer #'print-imm/asm-routine)

;;; Used by those instructions that have a default operand size of
;;; :qword. Nevertheless the immediate is at most of size :dword.
;;; The only instruction of this kind having a variant with an immediate
;;; argument is PUSH.
(define-arg-type signed-imm-data-default-qword
  :prefilter (lambda (dstate)
               (let ((nbits (* (size-nbyte (inst-operand-size-default-qword dstate))
                               n-byte-bits)))
                 (when (= nbits 64)
                   (setf nbits 32))
                 (read-signed-suffix nbits dstate))))

(define-arg-type signed-imm-byte
  :prefilter (lambda (dstate)
               (read-signed-suffix 8 dstate)))

(define-arg-type imm-byte
  :prefilter (lambda (dstate)
               (read-suffix 8 dstate)))

;;; needed for the ret imm16 instruction
(define-arg-type imm-word-16
  :prefilter (lambda (dstate)
               (read-suffix 16 dstate)))

(define-arg-type reg/mem
  :prefilter #'prefilter-reg/mem
  :printer #'print-reg/mem)
(define-arg-type sized-reg/mem
  ;; Same as reg/mem, but prints an explicit size indicator for
  ;; memory references.
  :prefilter #'prefilter-reg/mem
  :printer #'print-sized-reg/mem)

;;; Arguments of type reg/mem with a fixed size.
(define-arg-type sized-byte-reg/mem
  :prefilter #'prefilter-reg/mem
  :printer #'print-sized-byte-reg/mem)
(define-arg-type sized-word-reg/mem
  :prefilter #'prefilter-reg/mem
  :printer #'print-sized-word-reg/mem)
(define-arg-type sized-dword-reg/mem
  :prefilter #'prefilter-reg/mem
  :printer #'print-sized-dword-reg/mem)

;;; Same as sized-reg/mem, but with a default operand size of :qword.
(define-arg-type sized-reg/mem-default-qword
  :prefilter #'prefilter-reg/mem
  :printer #'print-sized-reg/mem-default-qword)

;;; XMM registers
(define-arg-type xmmreg
  :prefilter #'prefilter-reg-r
  :printer #'print-xmmreg)

(define-arg-type xmmreg-b
  :prefilter #'prefilter-reg-b
  :printer #'print-xmmreg)

(define-arg-type xmmreg/mem
  :prefilter #'prefilter-reg/mem
  :printer #'print-xmmreg/mem)

(defconstant-eqx +conditions+
  '((:o . 0)
    (:no . 1)
    (:b . 2) (:nae . 2) (:c . 2)
    (:nb . 3) (:ae . 3) (:nc . 3)
    (:eq . 4) (:e . 4) (:z . 4)
    (:ne . 5) (:nz . 5)
    (:be . 6) (:na . 6)
    (:nbe . 7) (:a . 7)
    (:s . 8)
    (:ns . 9)
    (:p . 10) (:pe . 10)
    (:np . 11) (:po . 11)
    (:l . 12) (:nge . 12)
    (:nl . 13) (:ge . 13)
    (:le . 14) (:ng . 14)
    (:nle . 15) (:g . 15))
  #'equal)
(defconstant-eqx sb!vm::+condition-name-vec+
  #.(let ((vec (make-array 16 :initial-element nil)))
      (dolist (cond +conditions+ vec)
        (when (null (aref vec (cdr cond)))
          (setf (aref vec (cdr cond)) (car cond)))))
  #'equalp)

;;; SSE shuffle patterns. The names end in the number of bits of the
;;; immediate byte that are used to encode the pattern and the radix
;;; in which to print the value.
(macrolet ((define-sse-shuffle-arg-type (name format-string)
               `(define-arg-type ,name
                  :type 'imm-byte
                  :printer (lambda (value stream dstate)
                             (declare (type (unsigned-byte 8) value)
                                      (type stream stream)
                                      (ignore dstate))
                             (format stream ,format-string value)))))
  (define-sse-shuffle-arg-type sse-shuffle-pattern-2-2 "#b~2,'0B")
  (define-sse-shuffle-arg-type sse-shuffle-pattern-8-4 "#4r~4,4,'0R"))

(define-arg-type condition-code :printer sb!vm::+condition-name-vec+)

(defun conditional-opcode (condition)
  (cdr (assoc condition +conditions+ :test #'eq)))

;;;; disassembler instruction formats

(defun swap-if (direction field1 separator field2)
    `(:if (,direction :constant 0)
          (,field1 ,separator ,field2)
          (,field2 ,separator ,field1)))

(define-instruction-format (byte 8 :default-printer '(:name))
  (op    :field (byte 8 0))
  ;; optional fields
  (accum :type 'accum)
  (imm))

(define-instruction-format (two-bytes 16
                                        :default-printer '(:name))
  (op :fields (list (byte 8 0) (byte 8 8))))

(define-instruction-format (three-bytes 24
                                        :default-printer '(:name))
  (op :fields (list (byte 8 0) (byte 8 8) (byte 8 16))))

;;; Prefix instructions

(define-instruction-format (rex 8)
  (rex     :field (byte 4 4)    :value #b0100)
  (wrxb    :field (byte 4 0)    :type 'wrxb))

(define-instruction-format (x66 8)
  (x66     :field (byte 8 0)    :type 'x66      :value #x66))

;;; A one-byte instruction with a #x66 prefix, used to indicate an
;;; operand size of :word.
(define-instruction-format (x66-byte 16
                                        :default-printer '(:name))
  (x66   :field (byte 8 0) :value #x66)
  (op    :field (byte 8 8)))

;;; A one-byte instruction with a REX prefix, used to indicate an
;;; operand size of :qword. REX.W must be 1, the other three bits are
;;; ignored.
(define-instruction-format (rex-byte 16
                                        :default-printer '(:name))
  (rex   :field (byte 5 3) :value #b01001)
  (op    :field (byte 8 8)))

(define-instruction-format (simple 8)
  (op    :field (byte 7 1))
  (width :field (byte 1 0) :type 'width)
  ;; optional fields
  (accum :type 'accum)
  (imm))

;;; Same as simple, but with direction bit
(define-instruction-format (simple-dir 8 :include simple)
  (op :field (byte 6 2))
  (dir :field (byte 1 1)))

;;; Same as simple, but with the immediate value occurring by default,
;;; and with an appropiate printer.
(define-instruction-format (accum-imm 8
                                     :include simple
                                     :default-printer '(:name
                                                        :tab accum ", " imm))
  (imm :type 'signed-imm-data))

(define-instruction-format (reg-no-width 8
                                     :default-printer '(:name :tab reg))
  (op    :field (byte 5 3))
  (reg   :field (byte 3 0) :type 'reg-b)
  ;; optional fields
  (accum :type 'accum)
  (imm))

;;; This is reg-no-width with a mandatory REX prefix and accum field,
;;; with the ability to match against REX.W and REX.B individually.
;;; REX.R and REX.X are ignored.
(define-instruction-format (rex-accum-reg 16
                                       :default-printer
                                       '(:name :tab accum ", " reg))
  (rex   :field (byte 4 4) :value #b0100)
  (rex-w :field (byte 1 3) :type 'rex-w)
  (rex-b :field (byte 1 0) :type 'rex-b)
  (op    :field (byte 5 11))
  (reg   :field (byte 3 8) :type 'reg-b)
  (accum :type 'accum))

;;; Same as reg-no-width, but with a default operand size of :qword.
(define-instruction-format (reg-no-width-default-qword 8
                                        :include reg-no-width
                                        :default-printer '(:name :tab reg))
  (reg   :type 'reg-b-default-qword))

;;; Adds a width field to reg-no-width. Note that we can't use
;;; :INCLUDE REG-NO-WIDTH here to save typing because that would put
;;; the WIDTH field last, but the prefilter for WIDTH must run before
;;; the one for IMM to be able to determine the correct size of IMM.
(define-instruction-format (reg 8
                                        :default-printer '(:name :tab reg))
  (op    :field (byte 4 4))
  (width :field (byte 1 3) :type 'width)
  (reg   :field (byte 3 0) :type 'reg-b)
  ;; optional fields
  (accum :type 'accum)
  (imm))

(declaim (inline !regrm-inst-reg))
(define-instruction-format (reg-reg/mem 16
                                        :default-printer
                                        `(:name :tab reg ", " reg/mem))
  (op      :field (byte 7 1))
  (width   :field (byte 1 0)    :type 'width)
  (reg/mem :fields (list (byte 2 14) (byte 3 8))
           :type 'reg/mem :reader regrm-inst-r/m)
  (reg     :field (byte 3 11)   :type 'reg :reader !regrm-inst-reg)
  ;; optional fields
  (imm))

;;; same as reg-reg/mem, but with direction bit
(define-instruction-format (reg-reg/mem-dir 16
                                        :include reg-reg/mem
                                        :default-printer
                                        `(:name
                                          :tab
                                          ,(swap-if 'dir 'reg/mem ", " 'reg)))
  (op  :field (byte 6 2))
  (dir :field (byte 1 1)))

;;; Same as reg-reg/mem, but uses the reg field as a second op code.
(define-instruction-format (reg/mem 16
                                        :default-printer '(:name :tab reg/mem))
  (op      :fields (list (byte 7 1) (byte 3 11)))
  (width   :field (byte 1 0)    :type 'width)
  (reg/mem :fields (list (byte 2 14) (byte 3 8))
                                :type 'sized-reg/mem)
  ;; optional fields
  (imm))

;;; Same as reg/mem, but without a width field and with a default
;;; operand size of :qword.
(define-instruction-format (reg/mem-default-qword 16
                                        :default-printer '(:name :tab reg/mem))
  (op      :fields (list (byte 8 0) (byte 3 11)))
  (reg/mem :fields (list (byte 2 14) (byte 3 8))
                                :type 'sized-reg/mem-default-qword))

;;; Same as reg/mem, but with the immediate value occurring by default,
;;; and with an appropiate printer.
(define-instruction-format (reg/mem-imm 16
                                        :include reg/mem
                                        :default-printer
                                        '(:name :tab reg/mem ", " imm))
  (reg/mem :type 'sized-reg/mem)
  (imm     :type 'signed-imm-data))

(define-instruction-format (reg/mem-imm/asm-routine 16
                                        :include reg/mem-imm
                                        :default-printer
                                        '(:name :tab reg/mem ", " imm))
  (reg/mem :type 'sized-reg/mem)
  (imm     :type 'signed-imm-data/asm-routine
           :reader reg/mem-imm-data))

;;; Same as reg/mem, but with using the accumulator in the default printer
(define-instruction-format
    (accum-reg/mem 16
     :include reg/mem :default-printer '(:name :tab accum ", " reg/mem))
  (reg/mem :type 'reg/mem)              ; don't need a size
  (accum :type 'accum))

;;; Same as reg-reg/mem, but with a prefix of #b00001111
(define-instruction-format (ext-reg-reg/mem 24
                                        :default-printer
                                        `(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0)    :value #x0F)
  (op      :field (byte 7 9))
  (width   :field (byte 1 8)    :type 'width)
  (reg/mem :fields (list (byte 2 22) (byte 3 16))
                                :type 'reg/mem)
  (reg     :field (byte 3 19)   :type 'reg)
  ;; optional fields
  (imm))

(define-instruction-format (ext-reg-reg/mem-no-width 24
                                        :default-printer
                                        `(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0)    :value #x0F)
  (op      :field (byte 8 8))
  (reg/mem :fields (list (byte 2 22) (byte 3 16))
                                :type 'reg/mem)
  (reg     :field (byte 3 19)   :type 'reg)
  ;; optional fields
  (imm))

(define-instruction-format (ext-reg/mem-no-width 24
                                        :default-printer
                                        `(:name :tab reg/mem))
  (prefix  :field (byte 8 0)    :value #x0F)
  (op      :fields (list (byte 8 8) (byte 3 19)))
  (reg/mem :fields (list (byte 2 22) (byte 3 16))
                                :type 'reg/mem))

;;; reg-no-width with #x0f prefix
(define-instruction-format (ext-reg-no-width 16
                                        :default-printer '(:name :tab reg))
  (prefix  :field (byte 8 0)    :value #x0F)
  (op    :field (byte 5 11))
  (reg   :field (byte 3 8) :type 'reg-b))

;;; Same as reg/mem, but with a prefix of #x0F
(define-instruction-format (ext-reg/mem 24
                                        :default-printer '(:name :tab reg/mem))
  (prefix  :field (byte 8 0)    :value #x0F)
  (op      :fields (list (byte 7 9) (byte 3 19)))
  (width   :field (byte 1 8)    :type 'width)
  (reg/mem :fields (list (byte 2 22) (byte 3 16))
                                :type 'sized-reg/mem)
  ;; optional fields
  (imm))

(define-instruction-format (ext-reg/mem-imm 24
                                        :include ext-reg/mem
                                        :default-printer
                                        '(:name :tab reg/mem ", " imm))
  (imm :type 'signed-imm-data))

(define-instruction-format (ext-reg/mem-no-width+imm8 24
                                        :include ext-reg/mem-no-width
                                        :default-printer
                                        '(:name :tab reg/mem ", " imm))
  (imm :type 'imm-byte))

;;;; XMM instructions

;;; All XMM instructions use an extended opcode (#x0F as the first
;;; opcode byte). Therefore in the following "EXT" in the name of the
;;; instruction formats refers to the formats that have an additional
;;; prefix (#x66, #xF2 or #xF3).

;;; Instructions having an XMM register as the destination operand
;;; and an XMM register or a memory location as the source operand.
;;; The size of the operands is implicitly given by the instruction.
(define-instruction-format (xmm-xmm/mem 24
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (x0f     :field (byte 8 0)    :value #x0f)
  (op      :field (byte 8 8))
  (reg/mem :fields (list (byte 2 22) (byte 3 16))
                                :type 'xmmreg/mem)
  (reg     :field (byte 3 19)   :type 'xmmreg)
  ;; optional fields
  (imm))

(define-instruction-format (ext-xmm-xmm/mem 32
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)    :value #x0f)
  (op      :field (byte 8 16))
  (reg/mem :fields (list (byte 2 30) (byte 3 24))
                                :type 'xmmreg/mem)
  (reg     :field (byte 3 27)   :type 'xmmreg)
  (imm))

(define-instruction-format (ext-rex-xmm-xmm/mem 40
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (rex     :field (byte 4 12)   :value #b0100)
  (wrxb    :field (byte 4 8)    :type 'wrxb)
  (x0f     :field (byte 8 16)   :value #x0f)
  (op      :field (byte 8 24))
  (reg/mem :fields (list (byte 2 38) (byte 3 32))
                                :type 'xmmreg/mem)
  (reg     :field (byte 3 35)   :type 'xmmreg)
  (imm))

(define-instruction-format (ext-2byte-xmm-xmm/mem 40
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)    :value #x0f)
  (op1     :field (byte 8 16))          ; #x38 or #x3a
  (op2     :field (byte 8 24))
  (reg/mem :fields (list (byte 2 38) (byte 3 32))
                                :type 'xmmreg/mem)
  (reg     :field (byte 3 35)   :type 'xmmreg))

(define-instruction-format (ext-rex-2byte-xmm-xmm/mem 48
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (rex     :field (byte 4 12)   :value #b0100)
  (wrxb    :field (byte 4 8)    :type 'wrxb)
  (x0f     :field (byte 8 16)   :value #x0f)
  (op1     :field (byte 8 24))          ; #x38 or #x3a
  (op2     :field (byte 8 32))
  (reg/mem :fields (list (byte 2 46) (byte 3 40))
                                :type 'xmmreg/mem)
  (reg     :field (byte 3 43)   :type 'xmmreg))

;;; Same as xmm-xmm/mem etc., but with direction bit.

(define-instruction-format (ext-xmm-xmm/mem-dir 32
                                        :include ext-xmm-xmm/mem
                                        :default-printer
                                        `(:name
                                          :tab
                                          ,(swap-if 'dir 'reg ", " 'reg/mem)))
  (op      :field (byte 7 17))
  (dir     :field (byte 1 16)))

(define-instruction-format (ext-rex-xmm-xmm/mem-dir 40
                                        :include ext-rex-xmm-xmm/mem
                                        :default-printer
                                        `(:name
                                          :tab
                                          ,(swap-if 'dir 'reg ", " 'reg/mem)))
  (op      :field (byte 7 25))
  (dir     :field (byte 1 24)))

;;; Instructions having an XMM register as one operand
;;; and a constant (unsigned) byte as the other.

(define-instruction-format (ext-xmm-imm 32
                                        :default-printer
                                        '(:name :tab reg/mem ", " imm))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)   :value #x0f)
  (op      :field (byte 8 16))
  (/i      :field (byte 3 27))
  (b11     :field (byte 2 30) :value #b11)
  (reg/mem :field (byte 3 24)
           :type 'xmmreg-b)
  (imm     :type 'imm-byte))

(define-instruction-format (ext-rex-xmm-imm 40
                                        :default-printer
                                        '(:name :tab reg/mem ", " imm))
  (prefix  :field (byte 8 0))
  (rex     :field (byte 4 12)   :value #b0100)
  (wrxb    :field (byte 4 8)    :type 'wrxb)
  (x0f     :field (byte 8 16)   :value #x0f)
  (op      :field (byte 8 24))
  (/i      :field (byte 3 35))
  (b11     :field (byte 2 38) :value #b11)
  (reg/mem :field (byte 3 32)
           :type 'xmmreg-b)
  (imm     :type 'imm-byte))

;;; Instructions having an XMM register as one operand and a general-
;;; -purpose register or a memory location as the other operand.

(define-instruction-format (xmm-reg/mem 24
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (x0f     :field (byte 8 0)    :value #x0f)
  (op      :field (byte 8 8))
  (reg/mem :fields (list (byte 2 22) (byte 3 16))
           :type 'sized-reg/mem)
  (reg     :field (byte 3 19)   :type 'xmmreg)
  (imm))

(define-instruction-format (ext-xmm-reg/mem 32
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)    :value #x0f)
  (op      :field (byte 8 16))
  (reg/mem :fields (list (byte 2 30) (byte 3 24))
                                :type 'sized-reg/mem)
  (reg     :field (byte 3 27)   :type 'xmmreg)
  (imm))

(define-instruction-format (ext-rex-xmm-reg/mem 40
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (rex     :field (byte 4 12)   :value #b0100)
  (wrxb    :field (byte 4 8)    :type 'wrxb)
  (x0f     :field (byte 8 16)   :value #x0f)
  (op      :field (byte 8 24))
  (reg/mem :fields (list (byte 2 38) (byte 3 32))
                                :type 'sized-reg/mem)
  (reg     :field (byte 3 35)   :type 'xmmreg)
  (imm))

(define-instruction-format (ext-2byte-xmm-reg/mem 40
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)    :value #x0f)
  (op1     :field (byte 8 16))
  (op2     :field (byte 8 24))
  (reg/mem :fields (list (byte 2 38) (byte 3 32)) :type 'sized-reg/mem)
  (reg     :field (byte 3 35)   :type 'xmmreg)
  (imm))

;;; Instructions having a general-purpose register as one operand and an
;;; XMM register or a memory location as the other operand.

(define-instruction-format (reg-xmm/mem 24
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (x0f     :field (byte 8 0)    :value #x0f)
  (op      :field (byte 8 8))
  (reg/mem :fields (list (byte 2 22) (byte 3 16))
                                :type 'xmmreg/mem)
  (reg     :field (byte 3 19)   :type 'reg))

(define-instruction-format (ext-reg-xmm/mem 32
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)    :value #x0f)
  (op      :field (byte 8 16))
  (reg/mem :fields (list (byte 2 30) (byte 3 24))
                                :type 'xmmreg/mem)
  (reg     :field (byte 3 27)   :type 'reg))

(define-instruction-format (ext-rex-reg-xmm/mem 40
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (rex     :field (byte 4 12)   :value #b0100)
  (wrxb    :field (byte 4 8)    :type 'wrxb)
  (x0f     :field (byte 8 16)   :value #x0f)
  (op      :field (byte 8 24))
  (reg/mem :fields (list (byte 2 38) (byte 3 32))
                                :type 'xmmreg/mem)
  (reg     :field (byte 3 35)   :type 'reg))

;;; Instructions having a general-purpose register or a memory location
;;; as one operand and an a XMM register as the other operand.

(define-instruction-format (ext-reg/mem-xmm 32
                                        :default-printer
                                        '(:name :tab reg/mem ", " reg))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)    :value #x0f)
  (op      :field (byte 8 16))
  (reg/mem :fields (list (byte 2 30) (byte 3 24))
                                :type 'reg/mem)
  (reg     :field (byte 3 27)   :type 'xmmreg)
  (imm))

(define-instruction-format (ext-rex-reg/mem-xmm 40
                                        :default-printer
                                        '(:name :tab reg/mem ", " reg))
  (prefix  :field (byte 8 0))
  (rex     :field (byte 4 12)   :value #b0100)
  (wrxb    :field (byte 4 8)    :type 'wrxb)
  (x0f     :field (byte 8 16)    :value #x0f)
  (op      :field (byte 8 24))
  (reg/mem :fields (list (byte 2 38) (byte 3 32))
                                :type 'reg/mem)
  (reg     :field (byte 3 35)   :type 'xmmreg)
  (imm))

(define-instruction-format (ext-2byte-reg/mem-xmm 40
                                        :default-printer
                                        '(:name :tab reg/mem ", " reg))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)    :value #x0f)
  (op1     :field (byte 8 16))
  (op2     :field (byte 8 24))
  (reg/mem :fields (list (byte 2 38) (byte 3 32)) :type 'reg/mem)
  (reg     :field (byte 3 35)   :type 'xmmreg)
  (imm))

(define-instruction-format (ext-rex-2byte-reg/mem-xmm 48
                                        :default-printer
                                        '(:name :tab reg/mem ", " reg))
  (prefix  :field (byte 8 0))
  (rex     :field (byte 4 12)   :value #b0100)
  (wrxb    :field (byte 4 8)    :type 'wrxb)
  (x0f     :field (byte 8 16)   :value #x0f)
  (op1     :field (byte 8 24))
  (op2     :field (byte 8 32))
  (reg/mem :fields (list (byte 2 46) (byte 3 40)) :type 'reg/mem)
  (reg     :field (byte 3 43)   :type 'xmmreg)
  (imm))

;;; Instructions having a general-purpose register as one operand and an a
;;; general-purpose register or a memory location as the other operand,
;;; and using a prefix byte.

(define-instruction-format (ext-prefix-reg-reg/mem 32
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)    :value #x0f)
  (op      :field (byte 8 16))
  (reg/mem :fields (list (byte 2 30) (byte 3 24))
                                :type 'sized-reg/mem)
  (reg     :field (byte 3 27)   :type 'reg))

(define-instruction-format (ext-rex-prefix-reg-reg/mem 40
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (rex     :field (byte 4 12)   :value #b0100)
  (wrxb    :field (byte 4 8)    :type 'wrxb)
  (x0f     :field (byte 8 16)   :value #x0f)
  (op      :field (byte 8 24))
  (reg/mem :fields (list (byte 2 38) (byte 3 32))
                                :type 'sized-reg/mem)
  (reg     :field (byte 3 35)   :type 'reg))

(define-instruction-format (ext-2byte-prefix-reg-reg/mem 40
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (x0f     :field (byte 8 8)    :value #x0f)
  (op1     :field (byte 8 16))          ; #x38 or #x3a
  (op2     :field (byte 8 24))
  (reg/mem :fields (list (byte 2 38) (byte 3 32))
                                :type 'sized-reg/mem)
  (reg     :field (byte 3 35)   :type 'reg))

(define-instruction-format (ext-rex-2byte-prefix-reg-reg/mem 48
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0))
  (rex     :field (byte 4 12)   :value #b0100)
  (wrxb    :field (byte 4 8)    :type 'wrxb)
  (x0f     :field (byte 8 16)   :value #x0f)
  (op1     :field (byte 8 24))          ; #x38 or #x3a
  (op2     :field (byte 8 32))
  (reg/mem :fields (list (byte 2 46) (byte 3 40))
                                :type 'sized-reg/mem)
  (reg     :field (byte 3 43)   :type 'reg))

;; XMM comparison instruction

(defconstant-eqx +sse-conditions+
    #(:eq :lt :le :unord :neq :nlt :nle :ord)
  #'equalp)

(define-arg-type sse-condition-code
  ;; Inherit the prefilter from IMM-BYTE to READ-SUFFIX the byte.
  :type 'imm-byte
  :printer +sse-conditions+)

(define-instruction-format (string-op 8
                                     :include simple
                                     :default-printer '(:name width)))

(define-instruction-format (short-cond-jump 16)
  (op    :field (byte 4 4) :value #b0111)
  (cc    :field (byte 4 0) :type 'condition-code)
  (label :field (byte 8 8) :type 'displacement))

(define-instruction-format (short-jump 16 :default-printer '(:name :tab label))
  (const :field (byte 4 4) :value #b1110)
  (op    :field (byte 4 0))
  (label :field (byte 8 8) :type 'displacement))

(define-instruction-format (near-cond-jump 48)
  (op    :fields (list (byte 8 0) (byte 4 12)) :value '(#x0F #b1000))
  (cc    :field (byte 4 8) :type 'condition-code)
  (label :field (byte 32 16) :type 'displacement :reader near-cond-jump-displacement))

(define-instruction-format (near-jump 40 :default-printer '(:name :tab label))
  (op    :field (byte 8 0))
  (label :field (byte 32 8) :type 'displacement :reader near-jump-displacement))

(define-instruction-format (cond-set 24 :default-printer '('set cc :tab reg/mem))
  (prefix :field (byte 8 0) :value #x0F)
  (op    :field (byte 4 12) :value #b1001)
  (cc    :field (byte 4 8) :type 'condition-code)
  (reg/mem :fields (list (byte 2 22) (byte 3 16))
           :type 'sized-byte-reg/mem)
  (reg     :field (byte 3 19)   :value #b000))

(define-instruction-format (cond-move 24
                                     :default-printer
                                        '('cmov cc :tab reg ", " reg/mem))
  (prefix  :field (byte 8 0)    :value #x0F)
  (op      :field (byte 4 12)   :value #b0100)
  (cc      :field (byte 4 8)    :type 'condition-code)
  (reg/mem :fields (list (byte 2 22) (byte 3 16))
                                :type 'reg/mem)
  (reg     :field (byte 3 19)   :type 'reg))

(define-instruction-format (enter-format 32
                                     :default-printer '(:name
                                                        :tab disp
                                                        (:unless (:constant 0)
                                                          ", " level)))
  (op :field (byte 8 0))
  (disp :field (byte 16 8))
  (level :field (byte 8 24)))

;;; Single byte instruction with an immediate byte argument.
(define-instruction-format (byte-imm 16 :default-printer '(:name :tab code))
 (op :field (byte 8 0))
 (code :field (byte 8 8) :reader byte-imm-code))

;;; Two byte instruction with an immediate byte argument.
;;;
(define-instruction-format (word-imm 24 :default-printer '(:name :tab code))
  (op :field (byte 16 0))
  (code :field (byte 8 16) :reader word-imm-code))

;;; F3 escape map - Needs a ton more work.

(define-instruction-format (F3-escape 24)
  (prefix1 :field (byte 8 0) :value #xF3)
  (prefix2 :field (byte 8 8) :value #x0F)
  (op      :field (byte 8 16)))

(define-instruction-format (rex-F3-escape 32)
  ;; F3 is a legacy prefix which was generalized to select an alternate opcode
  ;; map. Legacy prefixes are encoded in the instruction before a REX prefix.
  (prefix1 :field (byte 8 0)  :value #xF3)
  (rex     :field (byte 4 12) :value 4)    ; "prefix2"
  (wrxb    :field (byte 4 8)  :type 'wrxb)
  (prefix3 :field (byte 8 16) :value #x0F)
  (op      :field (byte 8 24)))

(define-instruction-format (F3-escape-reg-reg/mem 32
                                        :include F3-escape
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (reg/mem :fields (list (byte 2 30) (byte 3 24)) :type 'sized-reg/mem)
  (reg     :field  (byte 3 27) :type 'reg))

(define-instruction-format (rex-F3-escape-reg-reg/mem 40
                                        :include rex-F3-escape
                                        :default-printer
                                        '(:name :tab reg ", " reg/mem))
  (reg/mem :fields (list (byte 2 38) (byte 3 32)) :type 'sized-reg/mem)
  (reg     :field  (byte 3 35) :type 'reg))


;;;; primitive emitters

(define-bitfield-emitter emit-word 16
  (byte 16 0))

;; FIXME: a nice enhancement would be to save all sexprs of small functions
;; within the same file, and drop them at the end.
;; Expressly declaimed inline definitions would be saved as usual though.
(declaim (inline emit-dword))
(define-bitfield-emitter emit-dword 32
  (byte 32 0))
(declaim (notinline emit-dword))

(define-bitfield-emitter emit-qword 64
  (byte 64 0))

;;; Most uses of dwords are as displacements or as immediate values in
;;; 64-bit operations. In these cases they are sign-extended to 64 bits.
;;; EMIT-DWORD is unsuitable there because it accepts values of type
;;; (OR (SIGNED-BYTE 32) (UNSIGNED-BYTE 32)), so we provide a more
;;; restricted emitter here.
(defun emit-signed-dword (segment value)
  (declare (type sb!assem:segment segment)
           (type (signed-byte 32) value))
  (declare (inline emit-dword))
  (emit-dword segment value))

(define-bitfield-emitter emit-mod-reg-r/m-byte 8
  (byte 2 6) (byte 3 3) (byte 3 0))

(define-bitfield-emitter emit-sib-byte 8
  (byte 2 6) (byte 3 3) (byte 3 0))


;;;; fixup emitters

(defun emit-absolute-fixup (segment fixup &optional quad-p)
  (note-fixup segment (if quad-p :absolute64 :absolute) fixup)
  (let ((offset (fixup-offset fixup)))
    (if quad-p
        (emit-qword segment offset)
        (emit-signed-dword segment offset))))

(defun emit-relative-fixup (segment fixup)
  (note-fixup segment :relative fixup)
  (emit-signed-dword segment (fixup-offset fixup)))


;;;; the effective-address (ea) structure

(declaim (ftype (sfunction (tn) (mod 8)) reg-tn-encoding))
(defun reg-tn-encoding (tn)
  (declare (type tn tn))
  ;; ea only has space for three bits of register number: regs r8
  ;; and up are selected by a REX prefix byte which caller is responsible
  ;; for having emitted where necessary already
  (ecase (sb-name (sc-sb (tn-sc tn)))
    (registers
     (let ((offset (mod (tn-offset tn) 16)))
       (logior (ash (logand offset 1) 2)
               (ash offset -1))))
    (float-registers
     (mod (tn-offset tn) 8))))

(defmacro emit-bytes (segment &rest bytes)
  `(progn ,@(mapcar (lambda (x) `(emit-byte ,segment ,x)) bytes)))
(defun opcode+size-bit (opcode size)
  (if (eq size :byte) opcode (logior opcode 1)))
(defun emit-byte+reg (seg byte reg)
  (emit-byte seg (+ byte (reg-tn-encoding reg))))

;;; A label can refer to things near enough it using the addend.
(defstruct (label+addend (:constructor make-label+addend (label addend))
                         (:predicate nil)
                         (:copier nil)
                         (:include label))
  (label nil :type label)
  (addend 0 :type (signed-byte 32)))

(defstruct (ea (:constructor make-ea (size &key base index scale disp))
               (:copier nil))
  ;; note that we can represent an EA with a QWORD size, but EMIT-EA
  ;; can't actually emit it on its own: caller also needs to emit REX
  ;; prefix
  (size nil :type (member :byte :word :dword :qword) :read-only t)
  (base nil :type (or tn null) :read-only t)
  (index nil :type (or tn null) :read-only t)
  (scale 1 :type (member 1 2 4 8) :read-only t)
  (disp 0 :type (or (unsigned-byte 32) (signed-byte 32) fixup
                    label label+addend)
          :read-only t))
(defmethod print-object ((ea ea) stream)
  (cond ((or *print-escape* *print-readably*)
         (print-unreadable-object (ea stream :type t)
           (format stream
                   "~S~@[ base=~S~]~@[ index=~S~]~@[ scale=~S~]~@[ disp=~S~]"
                   (ea-size ea)
                   (let ((b (ea-base ea))) (if (eq b rip-tn) :RIP b))
                   (ea-index ea)
                   (let ((scale (ea-scale ea)))
                     (if (= scale 1) nil scale))
                   (ea-disp ea))))
        (t
         (format stream "~A PTR [" (symbol-name (ea-size ea)))
         (awhen (ea-base ea)
           (write-string (if (eq it rip-tn) "RIP" (sb!c:location-print-name it))
                         stream)
           (when (ea-index ea)
             (write-string "+" stream)))
         (when (ea-index ea)
           (write-string (sb!c:location-print-name (ea-index ea)) stream))
         (unless (= (ea-scale ea) 1)
           (format stream "*~A" (ea-scale ea)))
         (typecase (ea-disp ea)
           (integer
            (format stream "~@D" (ea-disp ea)))
           (t
            (format stream "+~A" (ea-disp ea))))
         (write-char #\] stream))))

(defun rip-relative-ea (size label &optional addend)
  (make-ea size :base rip-tn
                :disp (if addend
                          (make-label+addend label addend)
                          label)))

(defun sized-ea (ea new-size)
  (make-ea new-size
           :base (ea-base ea) :index (ea-index ea) :scale (ea-scale ea)
           :disp (ea-disp ea)))

(defun emit-byte-displacement-backpatch (segment target)
  (emit-back-patch segment 1
                   (lambda (segment posn)
                     (emit-byte segment
                                (the (signed-byte 8)
                                  (- (label-position target) (1+ posn)))))))

(defun emit-dword-displacement-backpatch (segment target &optional (n-extra 0))
  ;; N-EXTRA is how many more instruction bytes will follow, to properly compute
  ;; the displacement from the beginning of the next instruction to TARGET.
  (emit-back-patch segment 4
                   (lambda (segment posn)
                     (emit-signed-dword segment (- (label-position target)
                                                   (+ 4 posn n-extra))))))

(defun emit-ea (segment thing reg &key allow-constants (remaining-bytes 0))
  (etypecase thing
    (tn
     (ecase (sb-name (sc-sb (tn-sc thing)))
       ((registers float-registers)
        (emit-mod-reg-r/m-byte segment #b11 reg (reg-tn-encoding thing)))
       (stack
        ;; Could this be refactored to fall into the EA case below instead
        ;; of consing a new EA? Probably.  Does it matter? Probably not.
        (emit-ea segment
                 (make-ea :qword :base rbp-tn
                          :disp (frame-byte-offset (tn-offset thing)))
                 reg))
       (constant
        (unless allow-constants
          ;; Why?
          (error
           "Constant TNs can only be directly used in MOV, PUSH, and CMP."))
        ;; To access the constant at index 5 out of 6 constants, that's simply
        ;; word index -1 from the origin label, and so on.
        (emit-ea segment
                 (rip-relative-ea :qword
                                  (segment-origin segment) ; = word index 0
                                  (- (* (tn-offset thing) n-word-bytes)
                                     (component-header-length)))
                 reg :remaining-bytes remaining-bytes))))
    (ea
     (when (eq (ea-base thing) rip-tn)
       (aver (null (ea-index thing)))
       (let ((disp (ea-disp thing)))
         (aver (typep disp '(or label label+addend fixup)))
         (emit-mod-reg-r/m-byte segment #b00 reg #b101) ; RIP-relative mode
         (if (typep disp 'fixup)
             (emit-relative-fixup segment disp)
             (multiple-value-bind (label addend)
                 (if (typep disp 'label+addend)
                     (values (label+addend-label disp) (label+addend-addend disp))
                     (values disp 0))
               ;; To point at ADDEND bytes beyond the label, pretend that the PC
               ;; at which the EA occurs is _smaller_ by that amount.
               (emit-dword-displacement-backpatch
                segment label (- remaining-bytes addend)))))
       (return-from emit-ea))
     (let* ((base (ea-base thing))
            (index (ea-index thing))
            (scale (ea-scale thing))
            (disp (ea-disp thing))
            (mod (cond ((or (null base)
                            (and (eql disp 0)
                                 (not (= (reg-tn-encoding base) #b101))))
                        #b00)
                       ((and (fixnump disp) (<= -128 disp 127))
                        #b01)
                       (t
                        #b10)))
            (r/m (cond (index #b100)
                       ((null base) #b101)
                       (t (reg-tn-encoding base)))))
       (when (and (= mod 0) (= r/m #b101))
         ;; this is rip-relative in amd64, so we'll use a sib instead
         (setf r/m #b100 scale 1))
       (emit-mod-reg-r/m-byte segment mod reg r/m)
       (when (= r/m #b100)
         (let ((ss (1- (integer-length scale)))
               (index (if (null index)
                          #b100
                          (if (location= index sb!vm::rsp-tn)
                              (error "can't index off of RSP")
                              (reg-tn-encoding index))))
               (base (if (null base)
                         #b101
                         (reg-tn-encoding base))))
           (emit-sib-byte segment ss index base)))
       (cond ((= mod #b01)
              (emit-byte segment disp))
             ((or (= mod #b10) (null base))
              (if (fixup-p disp)
                  (emit-absolute-fixup segment disp)
                  (emit-signed-dword segment disp))))))
    (fixup
        (emit-mod-reg-r/m-byte segment #b00 reg #b100)
        (emit-sib-byte segment 0 #b100 #b101)
        (emit-absolute-fixup segment thing))))

(defun dword-reg-p (thing)
  (and (tn-p thing)
       (eq (sb-name (sc-sb (tn-sc thing))) 'registers)
       (eq (sb!c:sc-operand-size (tn-sc thing)) :dword)))

(defun qword-reg-p (thing)
  (and (tn-p thing)
       (eq (sb-name (sc-sb (tn-sc thing))) 'registers)
       (eq (sb!c:sc-operand-size (tn-sc thing)) :qword)))

;;; Return true if THING is a general-purpose register TN.
(defun gpr-p (thing)
  (and (tn-p thing)
       (eq (sb-name (sc-sb (tn-sc thing))) 'registers)))

(defun accumulator-p (thing)
  (and (gpr-p thing)
       (= (tn-offset thing) 0)))

;;; Return true if THING is an XMM register TN.
(defun xmm-register-p (thing)
  (and (tn-p thing)
       (eq (sb-name (sc-sb (tn-sc thing))) 'float-registers)))

(defun register-p (thing)
  (or (gpr-p thing) (xmm-register-p thing)))

;;;; utilities

(defconstant +operand-size-prefix-byte+ #b01100110)

(defconstant +regclass-gpr+ 0)
(defconstant +regclass-fpr+ 1)

;;; Size is :BYTE,:HIGH-BYTE,:WORD,:DWORD,:QWORD
;;; INDEX is the index in the register file for the class and size.
;;; TODO: may want to re-think whether the high byte registers are better
;;; represented with SIZE = :BYTE using an index number that is in a
;;; range that does not overlap 0 through 15, rather than a different "size"
;;; and a range that does overlap the :BYTE registers.
(defun make-gpr-id (size index)
  (declare (type (mod 16) index))
  (when (eq size :high-byte)
    (aver (<= 0 index 3))) ; only A,C,D,B have a corresponding 'h' register
  (logior (ash (position size #(:byte :high-byte :word :dword :qword)) 5)
          (ash index 1)))

(defun make-fpr-id (index)
  (declare (type (mod 16) index))
  (logior (ash index 1) 1)) ; low bit = FPR, not GPR

(defun reg-index (register-id)
  (ldb (byte 4 1) register-id))
(defun is-gpr-id-p (register-id)
  (not (logbitp 0 register-id)))
(defun gpr-size (register-id)
  (aref #(:byte :high-byte :word :dword :qword) (ldb (byte 3 5) register-id)))

(defun tn-reg-id (tn)
  (cond ((null tn) nil)
        ((eq (sb-name (sc-sb (tn-sc tn))) 'float-registers)
         (make-fpr-id (tn-offset tn)))
        (t
         (make-gpr-id (sc-operand-size (tn-sc tn))
                      (ash (tn-offset tn) -1)))))

(defun maybe-emit-operand-size-prefix (segment size)
  (unless (or (eq size :byte)
              (eq size :qword)          ; REX prefix handles this
              (eq size +default-operand-size+))
    (emit-byte segment +operand-size-prefix-byte+)))

;;; A REX prefix must be emitted if at least one of the following
;;; conditions is true:
;;; 1. Any of the WRXB bits are nonzero, which occurs if:
;;;    (a) The operand size is :QWORD and the default operand size of the
;;;        instruction is not :QWORD, or
;;;    (b) The instruction references a register above 7.
;;; 2. The instruction references one of the byte registers SIL, DIL,
;;;    SPL or BPL in the 'R' or 'B' encoding fields. X can be ignored
;;;    because the index in an EA is never byte-sized.

;;; Emit a REX prefix if necessary. WIDTH is used to determine
;;; whether to set REX.W. Callers pass it explicitly as :DO-NOT-SET if
;;; this should not happen, for example because the instruction's default
;;; operand size is qword. (FIXME: is totally redundant with NIL)
;;; R, X and B are NIL or REG-IDs specifying registers the encodings of
;;; which may be extended with the REX.R, REX.X and REX.B bit, respectively.
(defun emit-rex-if-needed (segment width r x b)
  (declare (type (member nil :byte :word :dword :qword :do-not-set) width)
           (type (or null fixnum) r x b))
  (flet ((encoding-bit3-p (reg-id)
           (and reg-id (logbitp 3 (reg-index reg-id))))
         (spl/bpl/sil/dil-p (reg-id)
           (and reg-id
                (is-gpr-id-p reg-id)
                (eq (gpr-size reg-id) :byte)
                (<= 4 (reg-index reg-id) 7))))
    (let ((wrxb (logior (if (eq width :qword)   #b1000 0)
                        (if (encoding-bit3-p r) #b0100 0)
                        (if (encoding-bit3-p x) #b0010 0)
                        (if (encoding-bit3-p b) #b0001 0))))
      (when (or (not (eql wrxb 0))
                (spl/bpl/sil/dil-p r)
                (spl/bpl/sil/dil-p b))
        (emit-byte segment (logior #x40 wrxb))))))

;;; Emit a REX prefix if necessary. The operand size is determined from
;;; THING or can be overridden by OPERAND-SIZE. This and REG are always
;;; passed to EMIT-REX-IF-NEEDED. Additionally, if THING is an EA we
;;; pass its index and base registers; if it is a register TN, we pass
;;; only itself.
;;; In contrast to EMIT-EA above, neither stack TNs nor fixups need to
;;; be treated specially here: If THING is a stack TN, neither it nor
;;; any of its components are passed to EMIT-REX-IF-NEEDED which
;;; works correctly because stack references always use RBP as the base
;;; register and never use an index register so no extended registers
;;; need to be accessed. Fixups are assembled using an addressing mode
;;; of displacement-only or RIP-plus-displacement (see EMIT-EA), so may
;;; not reference an extended register. The displacement-only addressing
;;; mode requires that REX.X is 0, which is ensured here.
(defun maybe-emit-rex-for-ea (segment thing reg &key operand-size)
  (declare (type (or ea tn fixup) thing)
           (type (or null tn) reg)
           (type (member nil :byte :word :dword :qword :do-not-set)
                 operand-size))
  (let ((ea-p (ea-p thing)))
    (emit-rex-if-needed    segment
                           (or operand-size (operand-size thing))
                           (tn-reg-id reg)
                           (and ea-p (tn-reg-id (ea-index thing)))
                           (cond (ea-p
                                  (let ((base (ea-base thing)))
                                    (unless (eq base rip-tn)
                                      (tn-reg-id base))))
                                 ((tn-p thing)
                                  (when (member (sb-name (sc-sb (tn-sc thing)))
                                                '(float-registers registers))
                                    (tn-reg-id thing)))
                                 (t nil)))))

(defun operand-size (thing)
  (typecase thing
    (tn
     (or (sb!c:sc-operand-size (tn-sc thing))
         (error "can't tell the size of ~S" thing)))
    (ea
     (ea-size thing))
    (fixup
     ;; GNA.  Guess who spelt "flavor" correctly first time round?
     ;; There's a strong argument in my mind to change all uses of
     ;; "flavor" to "kind": and similarly with some misguided uses of
     ;; "type" here and there.  -- CSR, 2005-01-06.
     (case (fixup-flavor thing)
       ((:foreign-dataref) :qword)))
    (t
     nil)))

(defun matching-operand-size (dst src)
  (let ((dst-size (operand-size dst))
        (src-size (operand-size src)))
    (if dst-size
        (if src-size
            (if (eq dst-size src-size)
                dst-size
                (error "size mismatch: ~S is a ~S and ~S is a ~S."
                       dst dst-size src src-size))
            dst-size)
        (if src-size
            src-size
            (error "can't tell the size of either ~S or ~S" dst src)))))

;;; Except in a very few cases (MOV instructions A1, A3 and B8 - BF)
;;; we expect dword immediate operands even for 64 bit operations.
;;; Those opcodes call EMIT-QWORD directly. All other uses of :qword
;;; constants should fit in a :dword
(defun emit-imm-operand (segment value size)
  ;; In order by descending popularity
  (ecase size
    (:byte  (emit-byte segment value))
    (:dword (emit-dword segment value))
    (:qword (emit-signed-dword segment value))
    (:word  (emit-word segment value))))

;;;; prefixes

(define-instruction rex (segment)
  (:printer rex () nil :print-name nil))

(define-instruction x66 (segment)
  (:printer x66 () nil :print-name nil))

(defun emit-prefix (segment name)
  (declare (ignorable segment))
  (ecase name
    ((nil))
    (:lock
     #!+sb-thread
     (emit-byte segment #xf0))))

(define-instruction fs (segment)
  (:emitter (emit-byte segment #x64))
  (:printer byte ((op #x64 :prefilter (lambda (dstate value)
                                        (declare (ignore value))
                                        (dstate-setprop dstate +fs-segment+))))
            nil :print-name nil))

(define-instruction lock (segment)
  (:printer byte ((op #xF0)) nil))

(define-instruction rep (segment)
  (:emitter (emit-byte segment #xF3)))

(define-instruction repe (segment)
  (:printer byte ((op #xF3)) nil)
  (:emitter (emit-byte segment #xF3)))

(define-instruction repne (segment)
  (:printer byte ((op #xF2)) nil)
  (:emitter (emit-byte segment #xF2)))

;;;; general data transfer

(define-instruction mov (segment dst src)
  ;; immediate to register
  (:printer reg ((op #b1011 :prefilter (lambda (dstate value)
                                         (dstate-setprop dstate +allow-qword-imm+)
                                         value))
                 (imm nil :type 'signed-imm-data/asm-routine))
            '(:name :tab reg ", " imm))
  ;; register to/from register/memory
  (:printer reg-reg/mem-dir ((op #b100010)))
  ;; immediate to register/memory
  (:printer reg/mem-imm/asm-routine ((op '(#b1100011 #b000))))

  (:emitter
   (let ((size (matching-operand-size dst src)))
     (maybe-emit-operand-size-prefix segment size)
     (cond ((gpr-p dst)
            (cond ((integerp src)
                   ;; We want to encode the immediate using the fewest bytes possible.
                   (let ((imm-size
                          ;; If it's a :qword constant that fits in an unsigned
                          ;; :dword, then use a zero-extended :dword immediate.
                          (if (and (eq size :qword) (typep src '(unsigned-byte 32)))
                              :dword
                              size)))
                     (emit-rex-if-needed segment imm-size
                                         nil nil (tn-reg-id dst)))
                   (acond ((neq size :qword) ; :dword or smaller dst is straightforward
                           (emit-byte+reg segment (if (eq size :byte) #xB0 #xB8) dst)
                           (emit-imm-operand segment src size))
                          ;; This must be move to a :qword register.
                          ((typep src '(unsigned-byte 32))
                           ;; Encode as B8+dst using operand size of 32 bits
                           ;; and implicit zero-extension.
                           ;; Instruction size: 5 if no REX prefix, or 6 with.
                           (emit-byte+reg segment #xB8 dst)
                           (emit-dword segment src))
                          ((plausible-signed-imm32-operand-p src)
                           ;; It's either a signed-byte-32, or a large unsigned
                           ;; value whose 33 high bits are all 1.
                           ;; Encode as C7 which sign-extends a 32-bit imm to 64 bits.
                           ;; Instruction size: 7 bytes.
                           (emit-byte segment #xC7)
                           (emit-mod-reg-r/m-byte segment #b11 #b000 (reg-tn-encoding dst))
                           (emit-signed-dword segment it))
                          (t
                           ;; 64-bit immediate. Instruction size: 10 bytes.
                           (emit-byte+reg segment #xB8 dst)
                           (emit-qword segment src))))
                  ((and (fixup-p src)
                        (member (fixup-flavor src)
                                '(:named-call :static-call :assembly-routine
                                  :layout :immobile-object :foreign)))
                   (emit-rex-if-needed segment :dword nil nil (tn-reg-id dst))
                   (emit-byte+reg segment #xB8 dst)
                   (emit-absolute-fixup segment src))
                  (t
                   (maybe-emit-rex-for-ea segment src dst)
                   (emit-byte segment (opcode+size-bit #x8A size))
                   (emit-ea segment src (reg-tn-encoding dst)
                            :allow-constants t))))
           ((integerp src) ; imm to memory
            ;; C7 only deals with 32 bit immediates even if the
            ;; destination is a 64-bit location. The value is
            ;; sign-extended in this case.
            (let ((imm-size (if (eq size :qword) :dword size))
                  ;; If IMMEDIATE32-P returns NIL, use the original value,
                  ;; which will signal an error in EMIT-IMMEDIATE
                  (imm-val (or (and (eq size :qword)
                                    (plausible-signed-imm32-operand-p src))
                               src)))
              (maybe-emit-rex-for-ea segment dst nil)
              (emit-byte segment (opcode+size-bit #xC6 size))
              ;; The EA could be RIP-relative, thus it is important
              ;; to get :REMAINING-BYTES correct.
              (emit-ea segment dst #b000 :remaining-bytes (size-nbyte imm-size))
              (emit-imm-operand segment imm-val imm-size)))
           ((gpr-p src) ; reg to mem
            (maybe-emit-rex-for-ea segment dst src)
            (emit-byte segment (opcode+size-bit #x88 size))
            (emit-ea segment dst (reg-tn-encoding src)))
           ((fixup-p src)
            ;; Generally we can't MOV a fixupped value into an EA, since
            ;; MOV on non-registers can only take a 32-bit immediate arg.
            ;; Make an exception for :FOREIGN fixups (pretty much just
            ;; the runtime asm, since other foreign calls go through the
            ;; the linkage table) and for linkage table references, since
            ;; these should always end up in low memory.
            (aver (or (member (fixup-flavor src)
                              '(:foreign :foreign-dataref :symbol-tls-index
                                :assembly-routine :layout :immobile-object))
                      (eq (ea-size dst) :dword)))
            (maybe-emit-rex-for-ea segment dst nil)
            (emit-byte segment #xC7)
            (emit-ea segment dst #b000)
            (emit-absolute-fixup segment src))
           (t
            (error "bogus arguments to MOV: ~S ~S" dst src))))))

;;; MOVABS is not a mnemonic according to the CPU vendors, but every (dis)assembler
;;; in popular use chooses this mnemonic instead of MOV with an 8-byte operand.
;;; (Even with Intel-compatible syntax, LLVM produces MOVABS).
;;; A possible motive is that it makes round-trip disassembly + reassembly faithful
;;; to the original encoding.  If MOVABS were rendered as MOV on account of the
;;; operand fitting by chance in 4 bytes, then information loss would occur.
;;; On the other hand, information loss occurs with other operands whose immediate
;;; value could fit in 1 byte or 4 bytes, so I don't know that that's the full
;;; reasoning. But in this disassembler anyway, an EA holds only a 32-bit integer
;;; so it doesn't really work to shoehorn this into the MOV instruction emitter.
(define-instruction movabs (segment dst src)
  ;; absolute mem to/from accumulator
  (:printer simple-dir ((op #b101000) (imm nil :type 'imm-addr))
            `(:name :tab ,(swap-if 'dir 'accum ", " '("[" imm "]"))))
  (:emitter
   (multiple-value-bind (reg ea dir-bit)
       (if (gpr-p dst) (values dst src 0) (values src dst 2))
     (aver (and (accumulator-p reg) (typep ea 'word)))
     (let ((size (operand-size reg)))
       (maybe-emit-operand-size-prefix segment size)
       (emit-rex-if-needed segment size nil nil nil)
       (emit-byte segment (logior (opcode+size-bit #xA0 size) dir-bit))
       (emit-qword segment ea)))))

;; MOV[SZ]X - #x66 or REX selects the destination REG size, wherein :byte isn't
;; a possibility.  The 'width' bit selects a source r/m size of :byte or :word.
(define-instruction-format
    (move-with-extension 24 :include ext-reg-reg/mem
     :default-printer
     '(:name :tab reg ", "
       (:cond ((width :constant 0) (:using #'print-sized-byte-reg/mem reg/mem))
              (t (:using #'print-sized-word-reg/mem reg/mem)))))
  (width :prefilter nil)) ; doesn't affect DSTATE

;;; Emit a sign-extending (if SIGNED-P is true) or zero-extending move.
(flet ((emit* (segment dst src signed-p)
         (aver (gpr-p dst))
         (let ((dst-size (operand-size dst)) ; DST size governs the OPERAND-SIZE
               (src-size (operand-size src)) ; SRC size is controlled by the opcode
               (opcode (if signed-p #xBE #xB6)))
           ;; Zero-extending into a 64-bit register is the same as zero-extending
           ;; into the 32-bit register. If the source is also 32-bits, then it
           ;; needs to use our synthetic MOVZXD instruction, which is really MOV.
           (when (and (not signed-p) (eq dst-size :qword))
             (setf dst-size :dword))
           (aver (> (size-nbyte dst-size) (size-nbyte src-size)))
           (maybe-emit-operand-size-prefix segment dst-size)
           (maybe-emit-rex-for-ea segment src dst :operand-size dst-size)
           (if (eq src-size :dword)
               ;; AMD calls this MOVSXD. If emitted without REX.W, it writes
               ;; only 32 bits. That is discouraged, and we don't do it.
               ;; (As checked by the AVER that dst is strictly larger than src)
               (emit-byte segment #x63)
               (emit-bytes segment #x0F (opcode+size-bit opcode src-size)))
           (emit-ea segment src (reg-tn-encoding dst)))))

  (define-instruction movsx (segment dst src)
    (:printer move-with-extension ((op #b1011111)))
    (:printer reg-reg/mem ((op #b0110001) (width 1)
                           (reg/mem nil :type 'sized-dword-reg/mem)))
    (:emitter (emit* segment dst src :signed)))

  (define-instruction movzx (segment dst src)
    (:printer move-with-extension ((op #b1011011)))
    (:emitter (emit* segment dst src nil))))

;;; This instruction is merely MOVSX with constraints on src + dst size
;;; of :dword + :qword respectively. The mnemonic is specified by AMD
;;; but is redundant. Indeed gcc and clang on linux allow 'movsx %eax, %rbx',
;;; objdump shows it as 'movslq' (move-sign-extended-long-to-quad),
;;; and Apple clang doesn't accept this mnemonic as far as I could tell.
(define-instruction-macro movsxd (dst src) `(%movsxd ,dst ,src))
(defun %movsxd (dst src)
  (aver (and (gpr-p dst) (eq (operand-size dst) :qword)))
  (aver (eq (operand-size src) :dword))
  (inst movsx dst src))

;;; This is not a real amd64 instruction. It exists to simplify
;;; the vop generator for 32-bit array ref and sap-ref-32.
(define-instruction-macro movzxd (dst src) `(%movzxd ,dst ,src))
(defun %movzxd (dst src)
  (aver (and (gpr-p dst) (eq (operand-size dst) :qword)))
  (aver (eq (operand-size src) :dword))
  (inst mov (sb!vm::reg-in-size dst :dword) src))

(flet ((emit* (segment thing gpr-opcode mem-opcode subcode allowp)
         (let ((size (operand-size thing)))
           (aver (or (eq size :qword) (eq size :word)))
           (maybe-emit-operand-size-prefix segment size)
           (maybe-emit-rex-for-ea segment thing nil :operand-size :do-not-set)
           (cond ((gpr-p thing)
                  (emit-byte+reg segment gpr-opcode thing))
                  (t
                   (emit-byte segment mem-opcode)
                   (emit-ea segment thing subcode :allow-constants allowp))))))
  (define-instruction push (segment src)
    ;; register
    (:printer reg-no-width-default-qword ((op #b01010)))
    ;; register/memory
    (:printer reg/mem-default-qword ((op '(#xFF 6))))
    ;; immediate
    (:printer byte ((op #b01101010) (imm nil :type 'signed-imm-byte))
              '(:name :tab imm))
    (:printer byte ((op #b01101000)
                    (imm nil :type 'signed-imm-data-default-qword))
              '(:name :tab imm))
    ;; ### segment registers?
    (:emitter
     (cond ((integerp src)
            ;; REX.W is not needed for :qword immediates because the default
            ;; operand size is 64 bits and the immediate value (8 or 32 bits)
            ;; is always sign-extended.
            (binding* ((imm (or (plausible-signed-imm32-operand-p src) src))
                       ((opcode operand-size)
                        (if (typep imm '(signed-byte 8))
                            (values #x6A :byte)
                            (values #x68 :qword))))
              (emit-byte segment opcode)
              (emit-imm-operand segment imm operand-size)))
           (t
            (emit* segment src #x50 #xFF 6 t)))))

  (define-instruction pop (segment dst)
    (:printer reg-no-width-default-qword ((op #b01011)))
    (:printer reg/mem-default-qword ((op '(#x8F 0))))
    (:emitter (emit* segment dst #x58 #x8F 0 nil))))

;;; Compared to x86 we need to take two particularities into account
;;; here:
;;; * XCHG EAX, EAX can't be encoded as #x90 as the processor interprets
;;;   that opcode as NOP while XCHG EAX, EAX is specified to clear the
;;;   upper half of RAX. We need to use the long form #x87 #xC0 instead.
;;; * The opcode #x90 is not only used for NOP and XCHG RAX, RAX and
;;;   XCHG AX, AX, but also for XCHG RAX, R8 (and the corresponding 32-
;;;   and 16-bit versions). The printer for the NOP instruction (further
;;;   below) matches all these encodings so needs to be overridden here
;;;   for the cases that need to print as XCHG.
;;; Assembler and disassembler chained then map these special cases as
;;; follows:
;;;   (INST NOP)                 ->  90      ->  NOP
;;;   (INST XCHG RAX-TN RAX-TN)  ->  4890    ->  NOP
;;;   (INST XCHG EAX-TN EAX-TN)  ->  87C0    ->  XCHG EAX, EAX
;;;   (INST XCHG AX-TN AX-TN)    ->  6690    ->  NOP
;;;   (INST XCHG RAX-TN R8-TN)   ->  4990    ->  XCHG RAX, R8
;;;   (INST XCHG EAX-TN R8D-TN)  ->  4190    ->  XCHG EAX, R8D
;;;   (INST XCHG AX-TN R8W-TN)   ->  664190  ->  XCHG AX, R8W
;;; The disassembler additionally correctly matches encoding variants
;;; that the assembler doesn't generate, for example 4E90 prints as NOP
;;; and 4F90 as XCHG RAX, R8 (both because REX.R and REX.X are ignored).
(define-instruction xchg (segment operand1 operand2)
  ;; This printer matches all patterns that encode exchanging RAX with
  ;; R8, EAX with R8D, or AX with R8W. These consist of the opcode #x90
  ;; with a REX prefix with REX.B = 1, and possibly the #x66 prefix.
  ;; We rely on the prefix automatism for the #x66 prefix, but
  ;; explicitly match the REX prefix as we need to provide a value for
  ;; REX.B, and to override the NOP printer by virtue of a longer match.
  (:printer rex-accum-reg ((rex-b 1) (op #b10010) (reg #b000)))
  ;; Register with accumulator.
  (:printer reg-no-width ((op #b10010)) '(:name :tab accum ", " reg))
  ;; Register/Memory with Register.
  (:printer reg-reg/mem ((op #b1000011)))
  (:emitter
   (let ((size (matching-operand-size operand1 operand2)))
     (maybe-emit-operand-size-prefix segment size)
     (labels ((xchg-acc-with-something (acc something)
                (if (and (not (eq size :byte))
                         (gpr-p something)
                         ;; Don't use the short encoding for XCHG EAX, EAX:
                         (not (and (= (tn-offset something) sb!vm::eax-offset)
                                   (eq size :dword))))
                    (progn
                      (maybe-emit-rex-for-ea segment something acc)
                      (emit-byte+reg segment #x90 something))
                    (xchg-reg-with-something acc something)))
              (xchg-reg-with-something (reg something)
                (maybe-emit-rex-for-ea segment something reg)
                (emit-byte segment (opcode+size-bit #x86 size))
                (emit-ea segment something (reg-tn-encoding reg))))
       (cond ((accumulator-p operand1)
              (xchg-acc-with-something operand1 operand2))
             ((accumulator-p operand2)
              (xchg-acc-with-something operand2 operand1))
             ((gpr-p operand1)
              (xchg-reg-with-something operand1 operand2))
             ((gpr-p operand2)
              (xchg-reg-with-something operand2 operand1))
             (t
              (error "bogus args to XCHG: ~S ~S" operand1 operand2)))))))

(define-instruction lea (segment dst src)
  (:printer
   reg-reg/mem
   ((op #b1000110) (width 1)
    (reg/mem nil :use-label #'lea-compute-label :printer #'lea-print-ea)))
  (:emitter
   (aver (or (dword-reg-p dst) (qword-reg-p dst)))
   ;; This next assertion is somewhat meaningless, and so commented out.
   ;; But it can be added back in to find "weird" combinations
   ;; of EA size and destination register size.
   ;; Barring use of the address-size-override prefix, EAs don't really have a
   ;; size as distinct from the operation size. Since we treat them as sized
   ;; (for the moment, until the assembler is overhauled), then make sure that
   ;; someone didn't think that the destination size is implied by the source
   ;; size. i.e. make sure they actually match.
   #+nil
   (aver (or (eq (operand-size dst) (ea-size src))
             ;; allow :BYTE to act as sort of a generic EA size
             (eq (ea-size src) :byte)))
   (maybe-emit-rex-for-ea segment src dst
                          :operand-size (if (dword-reg-p dst) :dword :qword))
   (emit-byte segment #x8D)
   (emit-ea segment src (reg-tn-encoding dst))))

(define-instruction cmpxchg (segment dst src &optional prefix)
  ;; Register/Memory with Register.
  (:printer ext-reg-reg/mem ((op #b1011000)) '(:name :tab reg/mem ", " reg))
  (:emitter
   (aver (gpr-p src))
   (emit-prefix segment prefix)
   (let ((size (matching-operand-size src dst)))
     (maybe-emit-operand-size-prefix segment size)
     (maybe-emit-rex-for-ea segment dst src)
     (emit-bytes segment #x0F (opcode+size-bit #xB0 size))
     (emit-ea segment dst (reg-tn-encoding src)))))

(define-instruction cmpxchg16b (segment mem &optional prefix)
  (:printer ext-reg/mem-no-width ((op '(#xC7 1))))
  (:emitter
   (aver (not (gpr-p mem)))
   (emit-prefix segment prefix)
   (maybe-emit-rex-for-ea segment mem nil :operand-size :qword)
   (emit-bytes segment #x0F #xC7)
   (emit-ea segment mem 1)))

(define-instruction rdrand (segment dst)
  (:printer ext-reg/mem-no-width ((op '(#xC7 6))))
  (:emitter
   (aver (gpr-p dst))
   (maybe-emit-operand-size-prefix segment (operand-size dst))
   (maybe-emit-rex-for-ea segment dst nil)
   (emit-bytes segment #x0F #xC7)
   (emit-ea segment dst 6)))

;;;; flag control instructions

(macrolet ((def (mnemonic opcode)
             `(define-instruction ,mnemonic (segment)
                (:printer byte ((op ,opcode)))
                (:emitter (emit-byte segment ,opcode)))))
  (def wait  #x9B) ; Wait.
  (def pushf #x9C) ; Push flags.
  (def popf  #x9D) ; Pop flags.
  (def sahf  #x9E) ; Store AH into flags.
  (def lahf  #x9F) ; Load AH from flags.
  (def hlt   #xF4) ; Halt
  (def cmc   #xF5) ; Complement Carry Flag.
  (def clc   #xF8) ; Clear Carry Flag.
  (def stc   #xF9) ; Set Carry Flag.
  (def cli   #xFA) ; Clear Iterrupt Enable Flag.
  (def sti   #xFB) ; Set Interrupt Enable Flag.
  (def cld   #xFC) ; Clear Direction Flag.
  (def std   #xFD) ; Set Direction Flag.
)

;;;; arithmetic

(flet ((emit* (name segment prefix dst src opcode allowp)
         (emit-prefix segment prefix)
         (let ((size (matching-operand-size dst src)))
           (maybe-emit-operand-size-prefix segment size)
           (acond
            ((and (neq size :byte) (plausible-signed-imm8-operand-p src size))
             (maybe-emit-rex-for-ea segment dst nil)
             (emit-byte segment #x83)
             (emit-ea segment dst opcode :allow-constants allowp)
             (emit-byte segment it))
            ((or (integerp src)
                 (and (fixup-p src)
                      (memq (fixup-flavor src) '(:layout :immobile-object))))
             (maybe-emit-rex-for-ea segment dst nil)
             (cond ((accumulator-p dst)
                    (emit-byte segment
                               (opcode+size-bit (dpb opcode (byte 3 3) #b00000100)
                                                size)))
                   (t
                    (emit-byte segment (opcode+size-bit #x80 size))
                    (emit-ea segment dst opcode :allow-constants allowp)))
             (if (fixup-p src)
                 (emit-absolute-fixup segment src)
                 (let ((imm (or (and (eq size :qword)
                                     (plausible-signed-imm32-operand-p src))
                                src)))
                   (emit-imm-operand segment imm size))))
            (t
             (multiple-value-bind (reg/mem reg dir-bit)
                 (cond ((gpr-p src) (values dst src #b00))
                       ((gpr-p dst) (values src dst #b10))
                       (t (error "bogus operands to ~A" name)))
               (maybe-emit-rex-for-ea segment reg/mem reg)
               (emit-byte segment
                          (opcode+size-bit (dpb opcode (byte 3 3) dir-bit) size))
               (emit-ea segment reg/mem (reg-tn-encoding reg)
                        :allow-constants allowp)))))))
  (macrolet ((define (name subop &optional allow-constants)
               `(define-instruction ,name (segment dst src &optional prefix)
                  (:printer accum-imm ((op ,(dpb subop (byte 3 2) #b0000010))))
                  (:printer reg/mem-imm ((op '(#b1000000 ,subop))))
                  ;; The redundant encoding #x82 is invalid in 64-bit mode,
                  ;; therefore we force WIDTH to 1.
                  (:printer reg/mem-imm ((op '(#b1000001 ,subop)) (width 1)
                                         (imm nil :type 'signed-imm-byte)))
                  (:printer reg-reg/mem-dir ((op ,(dpb subop (byte 3 1) #b000000))))
                  (:emitter (emit* ,(string name) segment prefix dst src ,subop
                                   ,allow-constants)))))
    (define add #b000)
    (define adc #b010)
    (define sub #b101)
    (define sbb #b011)
    (define cmp #b111 t)
    (define and #b100)
    (define or  #b001)
    (define xor #b110)))

(flet ((emit* (segment prefix opcode subcode dst)
         (emit-prefix segment prefix)
         (let ((size (operand-size dst)))
           (maybe-emit-operand-size-prefix segment size)
           (maybe-emit-rex-for-ea segment dst nil)
           (emit-byte segment (opcode+size-bit (ash opcode 1) size))
           (emit-ea segment dst subcode))))
  (define-instruction not (segment dst &optional prefix)
    (:printer reg/mem ((op '(#b1111011 #b010))))
    (:emitter (emit* segment prefix #b1111011 #b010 dst)))
  (define-instruction neg (segment dst &optional prefix)
    (:printer reg/mem ((op '(#b1111011 #b011))))
    (:emitter (emit* segment prefix #b1111011 #b011 dst)))
  ;; The one-byte encodings for INC and DEC are used as REX prefixes
  ;; in 64-bit mode so we always use the two-byte form.
  (define-instruction inc (segment dst &optional prefix)
    (:printer reg/mem ((op '(#b1111111 #b000))))
    (:emitter (emit* segment prefix #b1111111 #b000 dst)))
  (define-instruction dec (segment dst &optional prefix)
    (:printer reg/mem ((op '(#b1111111 #b001))))
    (:emitter (emit* segment prefix #b1111111 #b001 dst))))

(define-instruction mul (segment dst src)
  (:printer accum-reg/mem ((op '(#b1111011 #b100))))
  (:emitter
   (let ((size (matching-operand-size dst src)))
     (aver (accumulator-p dst))
     (maybe-emit-operand-size-prefix segment size)
     (maybe-emit-rex-for-ea segment src nil)
     (emit-byte segment (opcode+size-bit #xF6 size))
     (emit-ea segment src #b100))))

(define-instruction-format (imul-3-operand 16 :include reg-reg/mem)
  (op    :fields (list (byte 6 2) (byte 1 0)) :value '(#b011010 1))
  (width :field (byte 1 1)
         :prefilter (lambda (dstate value)
                      (unless (eql value 0)
                        (dstate-setprop dstate +imm-size-8+))))
  (imm   :prefilter
         (lambda (dstate)
           (let ((nbytes
                  (if (dstate-getprop dstate +imm-size-8+)
                      1
                      (min 4 (size-nbyte (inst-operand-size dstate))))))
             (read-signed-suffix (* nbytes 8) dstate)))))

(define-instruction imul (segment dst &optional src imm)
  ;; default accum-reg/mem printer is wrong here because 1-operand imul
  ;; is very different from 2-operand, not merely a shorter syntax for it.
  (:printer accum-reg/mem ((op '(#b1111011 #b101))) '(:name :tab reg/mem))
  (:printer ext-reg-reg/mem-no-width ((op #xAF))) ; 2-operand
  (:printer imul-3-operand () '(:name :tab reg ", " reg/mem ", " imm))
  (:emitter
   (let ((operand-size (matching-operand-size dst src)))
     (cond ((not src) ; 1-operand form affects RDX:RAX or subregisters thereof
            (aver (not imm))
            (maybe-emit-operand-size-prefix segment operand-size)
            (maybe-emit-rex-for-ea segment dst nil)
            (emit-byte segment (opcode+size-bit #xF6 operand-size))
            (emit-ea segment dst #b101))
           (t
            (aver (neq operand-size :byte))
            ;; If two operands and the second is immediate, it's really 3-operand
            ;; form with the same dst and src, which has to be a register.
            (when (and (integerp src) (not imm))
              (setq imm src src dst))
            (let ((imm-size (if (typep imm '(signed-byte 8)) :byte operand-size)))
              (maybe-emit-operand-size-prefix segment operand-size)
              (maybe-emit-rex-for-ea segment src dst)
              (if imm
                  (emit-byte segment (if (eq imm-size :byte) #x6B #x69))
                  (emit-bytes segment #x0F #xAF))
              (emit-ea segment src (reg-tn-encoding dst))
              (if imm
                  (emit-imm-operand segment imm imm-size))))))))

(flet ((emit* (segment dst src subcode)
         (let ((size (matching-operand-size dst src)))
           (aver (accumulator-p dst))
           (maybe-emit-operand-size-prefix segment size)
           (maybe-emit-rex-for-ea segment src nil)
           (emit-byte segment (opcode+size-bit #xF6 size))
           (emit-ea segment src subcode))))
  (define-instruction div (segment dst src)
    (:printer accum-reg/mem ((op '(#b1111011 #b110))))
    (:emitter (emit* segment dst src #b110)))
  (define-instruction idiv (segment dst src)
    (:printer accum-reg/mem ((op '(#b1111011 #b111))))
    (:emitter (emit* segment dst src #b111))))

(define-instruction bswap (segment dst)
  (:printer ext-reg-no-width ((op #b11001)))
  (:emitter
   (let ((size (operand-size dst)))
     (aver (member size '(:dword :qword)))
     (emit-rex-if-needed segment size nil nil (tn-reg-id dst))
     (emit-byte segment #x0f)
     (emit-byte+reg segment #xC8 dst))))

;;; CBW -- Convert Byte to Word. AX <- sign_xtnd(AL)
(define-instruction cbw (segment)
  (:printer x66-byte ((op #x98)))
  (:emitter
   (maybe-emit-operand-size-prefix segment :word)
   (emit-byte segment #x98)))

;;; CWDE -- Convert Word To Double Word Extended. EAX <- sign_xtnd(AX)
(define-instruction cwde (segment)
  (:printer byte ((op #x98)))
  (:emitter
   (maybe-emit-operand-size-prefix segment :dword)
   (emit-byte segment #x98)))

;;; CDQE -- Convert Double Word To Quad Word Extended. RAX <- sign_xtnd(EAX)
(define-instruction cdqe (segment)
  (:printer rex-byte ((op #x98)))
  (:emitter
   (emit-rex-if-needed segment :qword nil nil nil)
   (emit-byte segment #x98)))

;;; CWD -- Convert Word to Double Word. DX:AX <- sign_xtnd(AX)
(define-instruction cwd (segment)
  (:printer x66-byte ((op #x99)))
  (:emitter
   (maybe-emit-operand-size-prefix segment :word)
   (emit-byte segment #x99)))

;;; CDQ -- Convert Double Word to Quad Word. EDX:EAX <- sign_xtnd(EAX)
(define-instruction cdq (segment)
  (:printer byte ((op #x99)))
  (:emitter
   (maybe-emit-operand-size-prefix segment :dword)
   (emit-byte segment #x99)))

;;; CQO -- Convert Quad Word to Octaword. RDX:RAX <- sign_xtnd(RAX)
(define-instruction cqo (segment)
  (:printer rex-byte ((op #x99)))
  (:emitter
   (emit-rex-if-needed segment :qword nil nil nil)
   (emit-byte segment #x99)))

(define-instruction xadd (segment dst src &optional prefix)
  ;; Register/Memory with Register.
  (:printer ext-reg-reg/mem ((op #b1100000)) '(:name :tab reg/mem ", " reg))
  (:emitter
   (aver (gpr-p src))
   (emit-prefix segment prefix)
   (let ((size (matching-operand-size src dst)))
     (maybe-emit-operand-size-prefix segment size)
     (maybe-emit-rex-for-ea segment dst src)
     (emit-bytes segment #x0F (opcode+size-bit #xC0 size))
     (emit-ea segment dst (reg-tn-encoding src)))))


;;;; logic

(define-instruction-format
    (shift-inst 16 :include reg/mem
     :default-printer '(:name :tab reg/mem ", " (:if (variablep :positive) 'cl 1)))
  (op :fields (list (byte 6 2) (byte 3 11)))
  (variablep :field (byte 1 1)))

(flet ((emit* (segment dst amount subcode)
         (multiple-value-bind (opcode immed)
             (case amount
               (:cl (values #b11010010 nil))
               (1   (values #b11010000 nil))
               (t   (values #b11000000 t)))
           (let ((size (operand-size dst)))
             (maybe-emit-operand-size-prefix segment size)
             (maybe-emit-rex-for-ea segment dst nil)
             (emit-byte segment (opcode+size-bit opcode size)))
           (emit-ea segment dst subcode)
           (when immed
             (emit-byte segment amount)))))
  (macrolet ((define (name subop)
               `(define-instruction ,name (segment dst amount)
                  (:printer shift-inst ((op '(#b110100 ,subop)))) ; shift by CL or 1
                  (:printer reg/mem-imm ((op '(#b1100000 ,subop))
                                         (imm nil :type 'imm-byte)))
                  (:emitter (emit* segment dst amount ,subop)))))
    (define rol #b000)
    (define ror #b001)
    (define rcl #b010)
    (define rcr #b011)
    (define shl #b100)
    (define shr #b101)
    (define sar #b111)))

(flet ((emit* (segment opcode dst src amt)
         (declare (type (or (member :cl) (mod 64)) amt))
         (let ((size (matching-operand-size dst src)))
           (when (eq size :byte)
             (error "Double shift requires word or larger operand"))
           (maybe-emit-operand-size-prefix segment size)
           (maybe-emit-rex-for-ea segment dst src)
           (emit-bytes segment #x0F
                       ;; SHLD = A4 or A5; SHRD = AC or AD
                       (dpb opcode (byte 1 3) (if (eq amt :cl) #xA5 #xA4)))
           (emit-ea segment dst (reg-tn-encoding src))
           (unless (eq amt :cl)
             (emit-byte segment amt)))))
  (macrolet ((define (name direction-bit op)
               `(define-instruction ,name (segment dst src amt)
                  (:printer ext-reg-reg/mem-no-width ((op ,(logior op #b100))
                                                      (imm nil :type 'imm-byte))
                            '(:name :tab reg/mem ", " reg ", " imm))
                  (:printer ext-reg-reg/mem-no-width ((op ,(logior op #b101)))
                            '(:name :tab reg/mem ", " reg ", " 'cl))
                  (:emitter (emit* segment ,direction-bit dst src amt)))))
    (define shld 0 #b10100000)
    (define shrd 1 #b10101000)))

(define-instruction test (segment this that)
  (:printer accum-imm ((op #b1010100)))
  (:printer reg/mem-imm ((op '(#b1111011 #b000))))
  ;; 'objdump -d' always shows the memory arg as the second operand,
  ;; so we should show it first operand since we use Intel syntax.
  (:printer reg-reg/mem ((op #b1000010)) '(:name :tab reg/mem ", " reg))
  (:emitter
   (let ((size (matching-operand-size this that)))
     (maybe-emit-operand-size-prefix segment size)
     ;; gas disallows the constant as the first arg (in at&t syntax)
     ;; but does allow a memory arg as either operand.
     (cond ((integerp this) (error "Inverted arguments to TEST"))
           ((integerp that)
            ;; TEST has no form that sign-extends an 8-bit immediate,
            ;; so all we need to be concerned with is whether a positive
            ;; qword is bitwise equivalent to a signed dword.
            (awhen (and (eq size :qword) (plausible-signed-imm32-operand-p that))
              (setq that it))
            (maybe-emit-rex-for-ea segment this nil)
            (cond ((accumulator-p this)
                   (emit-byte segment (opcode+size-bit #xA8 size)))
                  (t
                   (emit-byte segment (opcode+size-bit #xF6 size))
                   (emit-ea segment this #b000)))
            (emit-imm-operand segment that size))
           (t
            (when (and (gpr-p this) (typep that '(or tn ea)))
              (rotatef this that))
            (maybe-emit-rex-for-ea segment this that)
            (emit-byte segment (opcode+size-bit #x84 size))
            (emit-ea segment this (reg-tn-encoding that)))))))

;;;; string manipulation

(flet ((emit* (segment opcode size)
         (maybe-emit-operand-size-prefix segment size)
         (emit-rex-if-needed segment size nil nil nil)
         (emit-byte segment (opcode+size-bit (ash opcode 1) size))))
  (define-instruction movs (segment size)
    (:printer string-op ((op #b1010010)))
    (:emitter (emit* segment #b1010010 size)))

  (define-instruction cmps (segment size)
    (:printer string-op ((op #b1010011)))
    (:emitter (emit* segment #b1010011 size)))

  (define-instruction lods (segment acc)
    (:printer string-op ((op #b1010110)))
    (:emitter (aver (accumulator-p acc))
              (emit* segment #b1010110 (operand-size acc))))

  (define-instruction scas (segment acc)
    (:printer string-op ((op #b1010111)))
    (:emitter (aver (accumulator-p acc))
              (emit* segment #b1010111 (operand-size acc))))

  (define-instruction stos (segment acc)
    (:printer string-op ((op #b1010101)))
    (:emitter (aver (accumulator-p acc))
              (emit* segment #b1010101 (operand-size acc))))

  (define-instruction ins (segment acc)
    (:printer string-op ((op #b0110110)))
    (:emitter (aver (accumulator-p acc))
              (emit* segment #b0110110 (operand-size acc))))

  (define-instruction outs (segment acc)
    (:printer string-op ((op #b0110111)))
    (:emitter (aver (accumulator-p acc))
              (emit* segment #b0110111 (operand-size acc)))))

(define-instruction xlat (segment)
  (:printer byte ((op #b11010111)))
  (:emitter
   (emit-byte segment #b11010111)))


;;;; bit manipulation

(flet ((emit* (segment opcode dst src)
         (let ((size (matching-operand-size dst src)))
           (when (eq size :byte)
             (error "can't scan bytes: ~S" src))
           (maybe-emit-operand-size-prefix segment size)
           (maybe-emit-rex-for-ea segment src dst)
           (emit-bytes segment #x0F opcode)
           (emit-ea segment src (reg-tn-encoding dst)))))

  (define-instruction bsf (segment dst src)
    (:printer ext-reg-reg/mem-no-width ((op #xBC)))
    (:emitter (emit* segment #xBC dst src)))

  (define-instruction bsr (segment dst src)
    (:printer ext-reg-reg/mem-no-width ((op #xBD)))
    (:emitter (emit* segment #xBD dst src))))

(flet ((emit* (segment src index opcode)
         (let ((size (operand-size src)))
           (when (eq size :byte)
             (error "can't scan bytes: ~S" src))
           (maybe-emit-operand-size-prefix segment size)
           (cond ((integerp index)
                  (maybe-emit-rex-for-ea segment src nil)
                  (emit-bytes segment #x0F #xBA)
                  (emit-ea segment src opcode)
                  (emit-byte segment index))
                 (t
                  (maybe-emit-rex-for-ea segment src index)
                  (emit-bytes segment #x0F (dpb opcode (byte 3 3) #b10000011))
                  (emit-ea segment src (reg-tn-encoding index)))))))

  (macrolet ((define (inst opcode-extension)
               `(define-instruction ,inst (segment src index &optional prefix)
                  (:printer ext-reg/mem-no-width+imm8
                            ((op '(#xBA ,opcode-extension))
                             (reg/mem nil :type 'sized-reg/mem)))
                  (:printer ext-reg-reg/mem-no-width
                            ((op ,(dpb opcode-extension (byte 3 3) #b10000011))
                             (reg/mem nil :type 'sized-reg/mem))
                            '(:name :tab reg/mem ", " reg))
                  (:emitter
                   (emit-prefix segment prefix)
                   (emit* segment src index ,opcode-extension)))))
    (define bt  4)
    (define bts 5)
    (define btr 6)
    (define btc 7)))


;;;; control transfer

(define-instruction call (segment where)
  (:printer near-jump ((op #xE8)))
  (:printer reg/mem-default-qword ((op '(#xFF #b010))
                                   (reg/mem nil :printer #'print-jmp-ea)))
  (:emitter
   (typecase where
     (label
      (emit-byte segment #xE8) ; 32 bit relative
      (emit-dword-displacement-backpatch segment where))
     (fixup
      (emit-byte segment #xE8)
      (emit-relative-fixup segment where))
     (t
      (maybe-emit-rex-for-ea segment where nil :operand-size :do-not-set)
      (emit-byte segment #xFF)
      (emit-ea segment where #b010)))))

(define-instruction jmp (segment cond &optional where)
  ;; conditional jumps
  (:printer short-cond-jump () '('j cc :tab label))
  (:printer near-cond-jump () '('j cc :tab label))
  ;; unconditional jumps
  (:printer short-jump ((op #b1011)))
  (:printer near-jump ((op #xE9)))
  (:printer reg/mem-default-qword ((op '(#xFF #b100))
                                   (reg/mem nil :printer #'print-jmp-ea)))
  (:emitter
   (flet ((byte-disp-p (source target disp shrinkage) ; T if 1-byte displacement
            ;; If the displacement is (signed-byte 8), then we have the answer.
            ;; Otherwise, if the displacement is positive and could be 1 byte,
            ;; then we check if the post-shrinkage value is in range.
            (or (typep disp '(signed-byte 8))
                (and (> disp 0)
                     (<= (- disp shrinkage) 127)
                     (not (any-alignment-between-p segment source target))))))
     (cond
        (where
          (cond ((fixup-p where)
                 (emit-bytes segment #x0F
                             (dpb (conditional-opcode cond)
                                  (byte 4 0)
                                  #b10000000))
                 (emit-relative-fixup segment where))
                (t
                 (emit-chooser
                  segment 6 2 ; emit either 2 or 6 bytes
                  ;; The difference in encoding lengths is 4, therefore this
                  ;; preserves 4-byte alignment ("2 bits" as we put it).
                  (lambda (segment chooser posn delta-if-after)
                    (let ((disp (- (label-position where posn delta-if-after)
                                   (+ posn 2))))
                      (when (byte-disp-p chooser where disp 4)
                        (emit-byte segment
                                   (dpb (conditional-opcode cond)
                                        (byte 4 0)
                                        #b01110000))
                        (emit-byte-displacement-backpatch segment where)
                        t)))
                  (lambda (segment posn)
                    (let ((disp (- (label-position where) (+ posn 6))))
                      (emit-bytes segment #x0F
                                  (dpb (conditional-opcode cond)
                                       (byte 4 0)
                                       #b10000000))
                      (emit-signed-dword segment disp)))))))
         ((label-p (setq where cond))
          (emit-chooser
           segment 5 0 ; emit either 2 or 5 bytes; no alignment is preserved
           (lambda (segment chooser posn delta-if-after)
             (let ((disp (- (label-position where posn delta-if-after)
                            (+ posn 2))))
               (when (byte-disp-p chooser where disp 3)
                 (emit-byte segment #xEB)
                 (emit-byte-displacement-backpatch segment where)
                 t)))
           (lambda (segment posn)
             (let ((disp (- (label-position where) (+ posn 5))))
               (emit-byte segment #xE9)
               (emit-signed-dword segment disp)))))
         ((fixup-p where)
          (emit-byte segment #xE9)
          (emit-relative-fixup segment where))
         (t
          (unless (or (ea-p where) (tn-p where))
            (error "don't know what to do with ~A" where))
          ;; near jump defaults to 64 bit
          ;; w-bit in rex prefix is unnecessary
          (maybe-emit-rex-for-ea segment where nil :operand-size :do-not-set)
          (emit-byte segment #b11111111)
          (emit-ea segment where #b100))))))

(define-instruction ret (segment &optional stack-delta)
  (:printer byte ((op #xC3)))
  (:printer byte ((op #xC2) (imm nil :type 'imm-word-16)) '(:name :tab imm))
  (:emitter
   (cond ((and stack-delta (not (zerop stack-delta)))
          (emit-byte segment #xC2)
          (emit-word segment stack-delta))
         (t
          (emit-byte segment #xC3)))))

(define-instruction jrcxz (segment target)
  (:printer short-jump ((op #b0011)))
  (:emitter
   (emit-byte segment #xE3)
   (emit-byte-displacement-backpatch segment target)))

(define-instruction loop (segment target)
  (:printer short-jump ((op #b0010)))
  (:emitter
   (emit-byte segment #xE2)
   (emit-byte-displacement-backpatch segment target)))

(define-instruction loopz (segment target)
  (:printer short-jump ((op #b0001)))
  (:emitter
   (emit-byte segment #xE1)
   (emit-byte-displacement-backpatch segment target)))

(define-instruction loopnz (segment target)
  (:printer short-jump ((op #b0000)))
  (:emitter
   (emit-byte segment #xE0)
   (emit-byte-displacement-backpatch segment target)))

;;;; conditional move
(define-instruction cmov (segment cond dst src)
  (:printer cond-move ())
  (:emitter
   (aver (gpr-p dst))
   (let ((size (matching-operand-size dst src)))
     (aver (neq size :byte))
     (maybe-emit-operand-size-prefix segment size))
   (maybe-emit-rex-for-ea segment src dst)
   (emit-byte segment #x0F)
   (emit-byte segment (dpb (conditional-opcode cond) (byte 4 0) #b01000000))
   (emit-ea segment src (reg-tn-encoding dst) :allow-constants t)))

;;;; conditional byte set

(define-instruction set (segment dst cond)
  (:printer cond-set ())
  (:emitter
   (maybe-emit-rex-for-ea segment dst nil :operand-size :byte)
   (emit-byte segment #x0F)
   (emit-byte segment (dpb (conditional-opcode cond) (byte 4 0) #b10010000))
   (emit-ea segment dst #b000)))

;;;; enter/leave

(define-instruction enter (segment disp &optional (level 0))
  (:declare (type (unsigned-byte 16) disp)
            (type (unsigned-byte 8) level))
  (:printer enter-format ((op #xC8)))
  (:emitter
   (emit-byte segment #xC8)
   (emit-word segment disp)
   (emit-byte segment level)))

(define-instruction leave (segment)
  (:printer byte ((op #xC9)))
  (:emitter (emit-byte segment #xC9)))

;;;; interrupt instructions

(define-instruction break (segment &optional (code nil codep))
  #!-ud2-breakpoints (:printer byte-imm ((op (or #!+int4-breakpoints #xCE #xCC)))
                               '(:name :tab code) :control #'break-control)
  #!+ud2-breakpoints (:printer word-imm ((op #x0B0F))
                               '(:name :tab code) :control #'break-control)
  (:emitter
   #!-ud2-breakpoints (emit-byte segment (or #!+int4-breakpoints #xCE #xCC))
   ;; On darwin, trap handling via SIGTRAP is unreliable, therefore we
   ;; throw a sigill with 0x0b0f instead and check for this in the
   ;; SIGILL handler and pass it on to the sigtrap handler if
   ;; appropriate
   #!+ud2-breakpoints (emit-word segment #x0B0F)
   (when codep (emit-byte segment (the (unsigned-byte 8) code)))))

(define-instruction int (segment number)
  (:declare (type (unsigned-byte 8) number))
  (:printer byte-imm ((op #xCD)))
  (:emitter
   (etypecase number
     ((member 3 4)
      (emit-byte segment (if (eql number 4) #xCE #xCC)))
     ((unsigned-byte 8)
      (emit-bytes segment #xCD number)))))

(define-instruction iret (segment)
  (:printer byte ((op #xCF)))
  (:emitter (emit-byte segment #xCF)))

;;;; processor control

(define-instruction nop (segment)
  (:printer byte ((op #x90)))
  ;; multi-byte NOP
  (:printer ext-reg/mem-no-width ((op '(#x1f 0))) '(:name))
  (:emitter (emit-byte segment #x90)))

;;; Emit a sequence of single- or multi-byte NOPs to fill AMOUNT many
;;; bytes with the smallest possible number of such instructions.
(defun emit-long-nop (segment amount)
  (declare (type sb!assem:segment segment)
           (type index amount))
  ;; Pack all instructions into one byte vector to save space.
  (let* ((bytes #.(!coerce-to-specialized
                          #(#x90
                            #x66 #x90
                            #x0f #x1f #x00
                            #x0f #x1f #x40 #x00
                            #x0f #x1f #x44 #x00 #x00
                            #x66 #x0f #x1f #x44 #x00 #x00
                            #x0f #x1f #x80 #x00 #x00 #x00 #x00
                            #x0f #x1f #x84 #x00 #x00 #x00 #x00 #x00
                            #x66 #x0f #x1f #x84 #x00 #x00 #x00 #x00 #x00)
                          '(unsigned-byte 8)))
         (max-length (isqrt (* 2 (length bytes)))))
    (loop
      (let* ((count (min amount max-length))
             (start (ash (* count (1- count)) -1)))
        (dotimes (i count)
          (emit-byte segment (aref bytes (+ start i)))))
      (if (> amount max-length)
          (decf amount max-length)
          (return)))))

(define-instruction syscall (segment)
  (:printer two-bytes ((op '(#x0F #x05))))
  (:emitter (emit-bytes segment #x0F #x05)))


;;;; miscellaneous hackery

(define-instruction byte (segment byte)
  (:emitter
   (emit-byte segment byte)))

;;; Compute the distance backward to the base address of the code component
;;; containing this simple-fun header, measured in words.
(defun emit-header-data (segment type)
  (emit-back-patch segment
                   n-word-bytes
                   (lambda (segment posn)
                     (emit-qword
                      segment
                      (logior type
                              (ash (+ posn (- (component-header-length)
                                              (segment-header-skew segment)))
                                   (- n-widetag-bits word-shift)))))))

(define-instruction simple-fun-header-word (segment)
  (:emitter
   (emit-header-data segment
                     (logior simple-fun-widetag
                             #!+(and compact-instance-header (host-feature sb-xc-host))
                             (ash function-layout 32)))))


;;;; Instructions required to do floating point operations using SSE

;; Return a one- or two-element list of printers for SSE instructions.
;; The one-element list is used in the cases where the REX prefix is
;; really a prefix and thus automatically supported, the two-element
;; list is used when the REX prefix is used in an infix position.
(eval-when (:compile-toplevel :execute)
  (defun sse-inst-printer-list (inst-format-stem prefix opcode
                                &key more-fields printer)
    (let ((fields `(,@(when prefix
                        `((prefix ,prefix)))
                    (op ,opcode)
                    ,@more-fields))
          (inst-formats (if prefix
                            (list (symbolicate "EXT-" inst-format-stem)
                                  (symbolicate "EXT-REX-" inst-format-stem))
                            (list inst-format-stem))))
      (mapcar (lambda (inst-format)
                `(:printer ,inst-format ,fields ,@(if printer `(',printer))))
              inst-formats)))
  (defun 2byte-sse-inst-printer-list (inst-format-stem prefix op1 op2
                                       &key more-fields printer)
    (let ((fields `(,@(when prefix
                        `((prefix, prefix)))
                    (op1 ,op1)
                    (op2 ,op2)
                    ,@more-fields))
          (inst-formats (if prefix
                            (list (symbolicate "EXT-" inst-format-stem)
                                  (symbolicate "EXT-REX-" inst-format-stem))
                            (list inst-format-stem))))
      (mapcar (lambda (inst-format)
                `(:printer ,inst-format ,fields ,@(if printer `(',printer))))
              inst-formats))))

(defun emit-sse-inst (segment dst src prefix opcode
                      &key operand-size (remaining-bytes 0))
  (when prefix
    (emit-byte segment prefix))
  (if operand-size
      (maybe-emit-rex-for-ea segment src dst :operand-size operand-size)
      (maybe-emit-rex-for-ea segment src dst))
  (emit-bytes segment #x0f opcode)
  (emit-ea segment src (reg-tn-encoding dst) :remaining-bytes remaining-bytes))

;; 0110 0110:0000 1111:0111 00gg: 11 010 xmmreg:imm8

(defun emit-sse-inst-with-imm (segment dst/src imm
                               prefix opcode /i
                               &key operand-size)
  (aver (<= 0 /i 7))
  (when prefix
    (emit-byte segment prefix))
  ;; dst/src is encoded in the r/m field, not r; REX.B must be
  ;; set to use extended XMM registers
  (emit-rex-if-needed segment operand-size nil nil (tn-reg-id dst/src))
  (emit-byte segment #x0F)
  (emit-byte segment opcode)
  (emit-byte segment (logior (ash (logior #b11000 /i) 3)
                             (reg-tn-encoding dst/src)))
  (emit-byte segment imm))

(defun emit-sse-inst-2byte (segment dst src prefix op1 op2
                            &key operand-size (remaining-bytes 0))
  (when prefix
    (emit-byte segment prefix))
  (if operand-size
      (maybe-emit-rex-for-ea segment src dst :operand-size operand-size)
      (maybe-emit-rex-for-ea segment src dst))
  (emit-byte segment #x0f)
  (emit-byte segment op1)
  (emit-byte segment op2)
  (emit-ea segment src (reg-tn-encoding dst) :remaining-bytes remaining-bytes))

(macrolet
    ((define-imm-sse-instruction (name opcode /i)
         `(define-instruction ,name (segment dst/src imm)
            ,@(sse-inst-printer-list 'xmm-imm #x66 opcode
                                     :more-fields `((/i ,/i)))
            (:emitter
             (emit-sse-inst-with-imm segment dst/src imm
                                     #x66 ,opcode ,/i
                                     :operand-size :do-not-set)))))
  (define-imm-sse-instruction pslldq #x73 7)
  (define-imm-sse-instruction psllw-imm #x71 6)
  (define-imm-sse-instruction pslld-imm #x72 6)
  (define-imm-sse-instruction psllq-imm #x73 6)

  (define-imm-sse-instruction psraw-imm #x71 4)
  (define-imm-sse-instruction psrad-imm #x72 4)

  (define-imm-sse-instruction psrldq #x73 3)
  (define-imm-sse-instruction psrlw-imm #x71 2)
  (define-imm-sse-instruction psrld-imm #x72 2)
  (define-imm-sse-instruction psrlq-imm #x73 2))

;;; Emit an SSE instruction that has an XMM register as the destination
;;; operand and for which the size of the operands is implicitly given
;;; by the instruction.
(defun emit-regular-sse-inst (segment dst src prefix opcode
                              &key (remaining-bytes 0))
  (aver (xmm-register-p dst))
  (emit-sse-inst segment dst src prefix opcode
                 :operand-size :do-not-set
                 :remaining-bytes remaining-bytes))

(defun emit-regular-2byte-sse-inst (segment dst src prefix op1 op2
                                    &key (remaining-bytes 0))
  (aver (xmm-register-p dst))
  (emit-sse-inst-2byte segment dst src prefix op1 op2
                       :operand-size :do-not-set
                       :remaining-bytes remaining-bytes))

;;; Instructions having an XMM register as the destination operand
;;; and an XMM register or a memory location as the source operand.
;;; The operand size is implicitly given by the instruction.

(macrolet ((define-regular-sse-inst (name prefix opcode)
             `(define-instruction ,name (segment dst src)
                ,@(sse-inst-printer-list 'xmm-xmm/mem prefix opcode)
                (:emitter
                 (emit-regular-sse-inst segment dst src ,prefix ,opcode)))))
  ;; moves
  (define-regular-sse-inst movshdup #xf3 #x16)
  (define-regular-sse-inst movsldup #xf3 #x12)
  (define-regular-sse-inst movddup  #xf2 #x12)
  ;; logical
  (define-regular-sse-inst andpd    #x66 #x54)
  (define-regular-sse-inst andps    nil  #x54)
  (define-regular-sse-inst andnpd   #x66 #x55)
  (define-regular-sse-inst andnps   nil  #x55)
  (define-regular-sse-inst orpd     #x66 #x56)
  (define-regular-sse-inst orps     nil  #x56)
  (define-regular-sse-inst pand     #x66 #xdb)
  (define-regular-sse-inst pandn    #x66 #xdf)
  (define-regular-sse-inst por      #x66 #xeb)
  (define-regular-sse-inst pxor     #x66 #xef)
  (define-regular-sse-inst xorpd    #x66 #x57)
  (define-regular-sse-inst xorps    nil  #x57)
  ;; comparison
  (define-regular-sse-inst comisd   #x66 #x2f)
  (define-regular-sse-inst comiss   nil  #x2f)
  (define-regular-sse-inst ucomisd  #x66 #x2e)
  (define-regular-sse-inst ucomiss  nil  #x2e)
  ;; integer comparison
  (define-regular-sse-inst pcmpeqb  #x66 #x74)
  (define-regular-sse-inst pcmpeqw  #x66 #x75)
  (define-regular-sse-inst pcmpeqd  #x66 #x76)
  (define-regular-sse-inst pcmpgtb  #x66 #x64)
  (define-regular-sse-inst pcmpgtw  #x66 #x65)
  (define-regular-sse-inst pcmpgtd  #x66 #x66)
  ;; max/min
  (define-regular-sse-inst maxpd    #x66 #x5f)
  (define-regular-sse-inst maxps    nil  #x5f)
  (define-regular-sse-inst maxsd    #xf2 #x5f)
  (define-regular-sse-inst maxss    #xf3 #x5f)
  (define-regular-sse-inst minpd    #x66 #x5d)
  (define-regular-sse-inst minps    nil  #x5d)
  (define-regular-sse-inst minsd    #xf2 #x5d)
  (define-regular-sse-inst minss    #xf3 #x5d)
  ;; integer max/min
  (define-regular-sse-inst pmaxsw   #x66 #xee)
  (define-regular-sse-inst pmaxub   #x66 #xde)
  (define-regular-sse-inst pminsw   #x66 #xea)
  (define-regular-sse-inst pminub   #x66 #xda)
  ;; arithmetic
  (define-regular-sse-inst addpd    #x66 #x58)
  (define-regular-sse-inst addps    nil  #x58)
  (define-regular-sse-inst addsd    #xf2 #x58)
  (define-regular-sse-inst addss    #xf3 #x58)
  (define-regular-sse-inst addsubpd #x66 #xd0)
  (define-regular-sse-inst addsubps #xf2 #xd0)
  (define-regular-sse-inst divpd    #x66 #x5e)
  (define-regular-sse-inst divps    nil  #x5e)
  (define-regular-sse-inst divsd    #xf2 #x5e)
  (define-regular-sse-inst divss    #xf3 #x5e)
  (define-regular-sse-inst haddpd   #x66 #x7c)
  (define-regular-sse-inst haddps   #xf2 #x7c)
  (define-regular-sse-inst hsubpd   #x66 #x7d)
  (define-regular-sse-inst hsubps   #xf2 #x7d)
  (define-regular-sse-inst mulpd    #x66 #x59)
  (define-regular-sse-inst mulps    nil  #x59)
  (define-regular-sse-inst mulsd    #xf2 #x59)
  (define-regular-sse-inst mulss    #xf3 #x59)
  (define-regular-sse-inst rcpps    nil  #x53)
  (define-regular-sse-inst rcpss    #xf3 #x53)
  (define-regular-sse-inst rsqrtps  nil  #x52)
  (define-regular-sse-inst rsqrtss  #xf3 #x52)
  (define-regular-sse-inst sqrtpd   #x66 #x51)
  (define-regular-sse-inst sqrtps   nil  #x51)
  (define-regular-sse-inst sqrtsd   #xf2 #x51)
  (define-regular-sse-inst sqrtss   #xf3 #x51)
  (define-regular-sse-inst subpd    #x66 #x5c)
  (define-regular-sse-inst subps    nil  #x5c)
  (define-regular-sse-inst subsd    #xf2 #x5c)
  (define-regular-sse-inst subss    #xf3 #x5c)
  (define-regular-sse-inst unpckhpd #x66 #x15)
  (define-regular-sse-inst unpckhps nil  #x15)
  (define-regular-sse-inst unpcklpd #x66 #x14)
  (define-regular-sse-inst unpcklps nil  #x14)
  ;; integer arithmetic
  (define-regular-sse-inst paddb    #x66 #xfc)
  (define-regular-sse-inst paddw    #x66 #xfd)
  (define-regular-sse-inst paddd    #x66 #xfe)
  (define-regular-sse-inst paddq    #x66 #xd4)
  (define-regular-sse-inst paddsb   #x66 #xec)
  (define-regular-sse-inst paddsw   #x66 #xed)
  (define-regular-sse-inst paddusb  #x66 #xdc)
  (define-regular-sse-inst paddusw  #x66 #xdd)
  (define-regular-sse-inst pavgb    #x66 #xe0)
  (define-regular-sse-inst pavgw    #x66 #xe3)
  (define-regular-sse-inst pmaddwd  #x66 #xf5)
  (define-regular-sse-inst pmulhuw  #x66 #xe4)
  (define-regular-sse-inst pmulhw   #x66 #xe5)
  (define-regular-sse-inst pmullw   #x66 #xd5)
  (define-regular-sse-inst pmuludq  #x66 #xf4)
  (define-regular-sse-inst psadbw   #x66 #xf6)
  (define-regular-sse-inst psllw    #x66 #xf1)
  (define-regular-sse-inst pslld    #x66 #xf2)
  (define-regular-sse-inst psllq    #x66 #xf3)
  (define-regular-sse-inst psraw    #x66 #xe1)
  (define-regular-sse-inst psrad    #x66 #xe2)
  (define-regular-sse-inst psrlw    #x66 #xd1)
  (define-regular-sse-inst psrld    #x66 #xd2)
  (define-regular-sse-inst psrlq    #x66 #xd3)
  (define-regular-sse-inst psubb    #x66 #xf8)
  (define-regular-sse-inst psubw    #x66 #xf9)
  (define-regular-sse-inst psubd    #x66 #xfa)
  (define-regular-sse-inst psubq    #x66 #xfb)
  (define-regular-sse-inst psubsb   #x66 #xe8)
  (define-regular-sse-inst psubsw   #x66 #xe9)
  (define-regular-sse-inst psubusb  #x66 #xd8)
  (define-regular-sse-inst psubusw  #x66 #xd9)
  ;; conversion
  (define-regular-sse-inst cvtdq2pd #xf3 #xe6)
  (define-regular-sse-inst cvtdq2ps nil  #x5b)
  (define-regular-sse-inst cvtpd2dq #xf2 #xe6)
  (define-regular-sse-inst cvtpd2ps #x66 #x5a)
  (define-regular-sse-inst cvtps2dq #x66 #x5b)
  (define-regular-sse-inst cvtps2pd nil  #x5a)
  (define-regular-sse-inst cvtsd2ss #xf2 #x5a)
  (define-regular-sse-inst cvtss2sd #xf3 #x5a)
  (define-regular-sse-inst cvttpd2dq #x66 #xe6)
  (define-regular-sse-inst cvttps2dq #xf3 #x5b)
  ;; integer
  (define-regular-sse-inst packsswb  #x66 #x63)
  (define-regular-sse-inst packssdw  #x66 #x6b)
  (define-regular-sse-inst packuswb  #x66 #x67)
  (define-regular-sse-inst punpckhbw #x66 #x68)
  (define-regular-sse-inst punpckhwd #x66 #x69)
  (define-regular-sse-inst punpckhdq #x66 #x6a)
  (define-regular-sse-inst punpckhqdq #x66 #x6d)
  (define-regular-sse-inst punpcklbw #x66 #x60)
  (define-regular-sse-inst punpcklwd #x66 #x61)
  (define-regular-sse-inst punpckldq #x66 #x62)
  (define-regular-sse-inst punpcklqdq #x66 #x6c))

(macrolet ((define-xmm-shuffle-sse-inst (name prefix opcode n-bits radix)
               (let ((shuffle-pattern
                      (intern (format nil "SSE-SHUFFLE-PATTERN-~D-~D"
                                      n-bits radix))))
                 `(define-instruction ,name (segment dst src pattern)
                    ,@(sse-inst-printer-list
                        'xmm-xmm/mem prefix opcode
                        :more-fields `((imm nil :type ',shuffle-pattern))
                        :printer '(:name :tab reg ", " reg/mem ", " imm))

                    (:emitter
                     (aver (typep pattern '(unsigned-byte ,n-bits)))
                     (emit-regular-sse-inst segment dst src ,prefix ,opcode
                                            :remaining-bytes 1)
                     (emit-byte segment pattern))))))
  (define-xmm-shuffle-sse-inst pshufd  #x66 #x70 8 4)
  (define-xmm-shuffle-sse-inst pshufhw #xf3 #x70 8 4)
  (define-xmm-shuffle-sse-inst pshuflw #xf2 #x70 8 4)
  (define-xmm-shuffle-sse-inst shufpd  #x66 #xc6 2 2)
  (define-xmm-shuffle-sse-inst shufps  nil  #xc6 8 4))

;; MASKMOVDQU (dst is DS:RDI)
(define-instruction maskmovdqu (segment src mask)
  (:emitter
   (aver (xmm-register-p src))
   (aver (xmm-register-p mask))
   (emit-regular-sse-inst segment src mask #x66 #xf7))
  . #.(sse-inst-printer-list 'xmm-xmm/mem #x66 #xf7))

(macrolet ((define-comparison-sse-inst (name prefix opcode
                                        name-prefix name-suffix)
               `(define-instruction ,name (segment op x y)
                  ,@(sse-inst-printer-list
                      'xmm-xmm/mem prefix opcode
                      :more-fields '((imm nil :type 'sse-condition-code))
                      :printer `(,name-prefix imm ,name-suffix
                                 :tab reg ", " reg/mem))
                  (:emitter
                   (let ((code (position op +sse-conditions+)))
                     (aver code)
                     (emit-regular-sse-inst segment x y ,prefix ,opcode
                                            :remaining-bytes 1)
                     (emit-byte segment code))))))
  (define-comparison-sse-inst cmppd #x66 #xc2 "CMP" "PD")
  (define-comparison-sse-inst cmpps nil  #xc2 "CMP" "PS")
  (define-comparison-sse-inst cmpsd #xf2 #xc2 "CMP" "SD")
  (define-comparison-sse-inst cmpss #xf3 #xc2 "CMP" "SS"))

;;; MOVSD, MOVSS
(macrolet ((define-movsd/ss-sse-inst (name prefix)
             `(define-instruction ,name (segment dst src)
                ,@(sse-inst-printer-list 'xmm-xmm/mem-dir prefix #b0001000)
                (:emitter
                 (cond ((xmm-register-p dst)
                        (emit-sse-inst segment dst src ,prefix #x10
                                       :operand-size :do-not-set))
                       (t
                        (aver (xmm-register-p src))
                        (emit-sse-inst segment src dst ,prefix #x11
                                       :operand-size :do-not-set)))))))
  (define-movsd/ss-sse-inst movsd #xf2)
  (define-movsd/ss-sse-inst movss #xf3))

;;; Packed MOVs
(macrolet ((define-mov-sse-inst (name prefix opcode-from opcode-to
                                      &key force-to-mem reg-reg-name)
               `(progn
                  ,(when reg-reg-name
                     `(define-instruction ,reg-reg-name (segment dst src)
                        (:emitter
                         (aver (xmm-register-p dst))
                         (aver (xmm-register-p src))
                         (emit-regular-sse-inst segment dst src
                                                ,prefix ,opcode-from))))
                  (define-instruction ,name (segment dst src)
                    ,@(when opcode-from
                        (sse-inst-printer-list 'xmm-xmm/mem prefix opcode-from))
                    ,@(sse-inst-printer-list
                          'xmm-xmm/mem prefix opcode-to
                          :printer '(:name :tab reg/mem ", " reg))
                    (:emitter
                     (cond ,@(when opcode-from
                               `(((xmm-register-p dst)
                                  ,(when force-to-mem
                                     `(aver (not (register-p src))))
                                  (emit-regular-sse-inst
                                   segment dst src ,prefix ,opcode-from))))
                           (t
                            (aver (xmm-register-p src))
                            ,(when force-to-mem
                               `(aver (not (register-p dst))))
                            (emit-regular-sse-inst segment src dst
                                                   ,prefix ,opcode-to))))))))
  ;; direction bit?
  (define-mov-sse-inst movapd #x66 #x28 #x29)
  (define-mov-sse-inst movaps nil  #x28 #x29)
  (define-mov-sse-inst movdqa #x66 #x6f #x7f)
  (define-mov-sse-inst movdqu #xf3 #x6f #x7f)

  ;; streaming
  (define-mov-sse-inst movntdq #x66 nil #xe7 :force-to-mem t)
  (define-mov-sse-inst movntpd #x66 nil #x2b :force-to-mem t)
  (define-mov-sse-inst movntps nil  nil #x2b :force-to-mem t)

  ;; use movhps for movlhps and movlps for movhlps
  (define-mov-sse-inst movhpd #x66 #x16 #x17 :force-to-mem t)
  (define-mov-sse-inst movhps nil  #x16 #x17 :reg-reg-name movlhps)
  (define-mov-sse-inst movlpd #x66 #x12 #x13 :force-to-mem t)
  (define-mov-sse-inst movlps nil  #x12 #x13 :reg-reg-name movhlps)
  (define-mov-sse-inst movupd #x66 #x10 #x11)
  (define-mov-sse-inst movups nil  #x10 #x11))

;;; MOVNTDQA
(define-instruction movntdqa (segment dst src)
  (:emitter
   (aver (and (xmm-register-p dst)
              (not (xmm-register-p src))))
   (emit-regular-2byte-sse-inst segment dst src #x66 #x38 #x2a))
  . #.(2byte-sse-inst-printer-list '2byte-xmm-xmm/mem #x66 #x38 #x2a))

;;; MOVQ
(define-instruction movq (segment dst src)
  (:emitter
   (cond ((xmm-register-p dst)
          (emit-sse-inst segment dst src #xf3 #x7e
                         :operand-size :do-not-set))
         (t
          (aver (xmm-register-p src))
          (emit-sse-inst segment src dst #x66 #xd6
                         :operand-size :do-not-set))))
  . #.(append (sse-inst-printer-list 'xmm-xmm/mem #xf3 #x7e)
              (sse-inst-printer-list 'xmm-xmm/mem #x66 #xd6
                                     :printer '(:name :tab reg/mem ", " reg))))

;;; Instructions having an XMM register as the destination operand
;;; and a general-purpose register or a memory location as the source
;;; operand. The operand size is calculated from the source operand.

;;; MOVD - Move a 32- or 64-bit value from a general-purpose register or
;;; a memory location to the low order 32 or 64 bits of an XMM register
;;; with zero extension or vice versa.
;;; We do not support the MMX version of this instruction.
(define-instruction movd (segment dst src)
  (:emitter
   (cond ((xmm-register-p dst)
          (emit-sse-inst segment dst src #x66 #x6e))
         (t
          (aver (xmm-register-p src))
          (emit-sse-inst segment src dst #x66 #x7e))))
  . #.(append (sse-inst-printer-list 'xmm-reg/mem #x66 #x6e)
              (sse-inst-printer-list 'xmm-reg/mem #x66 #x7e
                                     :printer '(:name :tab reg/mem ", " reg))))

(macrolet ((define-extract-sse-instruction (name prefix op1 op2
                                            &key explicit-qword)
             `(define-instruction ,name (segment dst src imm)
                (:printer
                 ,(if op2 (if explicit-qword
                              'ext-rex-2byte-reg/mem-xmm
                              'ext-2byte-reg/mem-xmm)
                      'ext-reg/mem-xmm)
                 ((prefix '(,prefix))
                  ,@(if op2
                        `((op1 '(,op1)) (op2 '(,op2)))
                        `((op '(,op1))))
                  (imm nil :type 'imm-byte))
                 '(:name :tab reg/mem ", " reg ", " imm))
                (:emitter
                 (aver (and (xmm-register-p src) (not (xmm-register-p dst))))
                 ,(if op2
                      `(emit-sse-inst-2byte segment dst src ,prefix ,op1 ,op2
                                            :operand-size ,(if explicit-qword
                                                               :qword
                                                               :do-not-set)
                                            :remaining-bytes 1)
                      `(emit-sse-inst segment dst src ,prefix ,op1
                                      :operand-size ,(if explicit-qword
                                                         :qword
                                                         :do-not-set)
                                      :remaining-bytes 1))
                 (emit-byte segment imm))))

           (define-insert-sse-instruction (name prefix op1 op2)
             `(define-instruction ,name (segment dst src imm)
                (:printer
                 ,(if op2 'ext-2byte-xmm-reg/mem 'ext-xmm-reg/mem)
                 ((prefix '(,prefix))
                  ,@(if op2
                        `((op1 '(,op1)) (op2 '(,op2)))
                        `((op '(,op1))))
                  (imm nil :type 'imm-byte))
                 '(:name :tab reg ", " reg/mem ", " imm))
                (:emitter
                 (aver (and (xmm-register-p dst) (not (xmm-register-p src))))
                 ,(if op2
                      `(emit-sse-inst-2byte segment dst src ,prefix ,op1 ,op2
                                            :operand-size :do-not-set
                                            :remaining-bytes 1)
                      `(emit-sse-inst segment dst src ,prefix ,op1
                                      :operand-size :do-not-set
                                      :remaining-bytes 1))
                 (emit-byte segment imm)))))


  ;; pinsrq not encodable in 64-bit mode
  (define-insert-sse-instruction pinsrb #x66 #x3a #x20)
  (define-insert-sse-instruction pinsrw #x66 #xc4 nil)
  (define-insert-sse-instruction pinsrd #x66 #x3a #x22)
  (define-insert-sse-instruction insertps #x66 #x3a #x21)

  (define-extract-sse-instruction pextrb #x66 #x3a #x14)
  (define-extract-sse-instruction pextrd #x66 #x3a #x16)
  (define-extract-sse-instruction pextrq #x66 #x3a #x16 :explicit-qword t)
  (define-extract-sse-instruction extractps #x66 #x3a #x17))

;; PEXTRW has a new 2-byte encoding in SSE4.1 to allow dst to be
;; a memory address.
(define-instruction pextrw (segment dst src imm)
  (:emitter
   (aver (xmm-register-p src))
   (if (not (gpr-p dst))
       (emit-sse-inst-2byte segment dst src #x66 #x3a #x15
                            :operand-size :do-not-set :remaining-bytes 1)
       (emit-sse-inst segment dst src #x66 #xc5
                            :operand-size :do-not-set :remaining-bytes 1))
   (emit-byte segment imm))
  . #.(append
       (2byte-sse-inst-printer-list '2byte-reg/mem-xmm #x66 #x3a #x15
                                    :more-fields '((imm nil :type 'imm-byte))
                                    :printer '(:name :tab reg/mem ", " reg ", " imm))
       (sse-inst-printer-list 'reg/mem-xmm #x66 #xc5
                              :more-fields '((imm nil :type 'imm-byte))
                              :printer '(:name :tab reg/mem ", " reg ", " imm))))

(macrolet ((define-integer-source-sse-inst (name prefix opcode &key mem-only)
             `(define-instruction ,name (segment dst src)
                ,@(sse-inst-printer-list 'xmm-reg/mem prefix opcode)
                (:emitter
                 (aver (xmm-register-p dst))
                 ,(when mem-only
                    `(aver (not (register-p src))))
                 (let ((src-size (operand-size src)))
                   (aver (or (eq src-size :qword) (eq src-size :dword))))
                 (emit-sse-inst segment dst src ,prefix ,opcode)))))
  (define-integer-source-sse-inst cvtsi2sd #xf2 #x2a)
  (define-integer-source-sse-inst cvtsi2ss #xf3 #x2a)
  ;; FIXME: memory operand is always a QWORD
  (define-integer-source-sse-inst cvtpi2pd #x66 #x2a :mem-only t)
  (define-integer-source-sse-inst cvtpi2ps nil  #x2a :mem-only t))

;;; Instructions having a general-purpose register as the destination
;;; operand and an XMM register or a memory location as the source
;;; operand. The operand size is calculated from the destination
;;; operand.

(macrolet ((define-gpr-destination-sse-inst (name prefix opcode &key reg-only)
             `(define-instruction ,name (segment dst src)
                ,@(sse-inst-printer-list 'reg-xmm/mem prefix opcode)
                (:emitter
                 (aver (gpr-p dst))
                 ,(when reg-only
                    `(aver (xmm-register-p src)))
                 (let ((dst-size (operand-size dst)))
                   (aver (or (eq dst-size :qword) (eq dst-size :dword)))
                   (emit-sse-inst segment dst src ,prefix ,opcode
                                  :operand-size dst-size))))))
  (define-gpr-destination-sse-inst cvtsd2si  #xf2 #x2d)
  (define-gpr-destination-sse-inst cvtss2si  #xf3 #x2d)
  (define-gpr-destination-sse-inst cvttsd2si #xf2 #x2c)
  (define-gpr-destination-sse-inst cvttss2si #xf3 #x2c)
  (define-gpr-destination-sse-inst movmskpd  #x66 #x50 :reg-only t)
  (define-gpr-destination-sse-inst movmskps  nil  #x50 :reg-only t)
  (define-gpr-destination-sse-inst pmovmskb  #x66 #xd7 :reg-only t))

;;;; We call these "2byte" instructions due to their two opcode bytes.
;;;; Intel and AMD call them three-byte instructions, as they count the
;;;; 0x0f byte for determining the number of opcode bytes.

;;; Instructions that take XMM-XMM/MEM and XMM-XMM/MEM-IMM arguments.

(macrolet ((regular-2byte-sse-inst (name prefix op1 op2)
             `(define-instruction ,name (segment dst src)
                ,@(2byte-sse-inst-printer-list '2byte-xmm-xmm/mem prefix
                                                op1 op2)
                (:emitter
                 (emit-regular-2byte-sse-inst segment dst src ,prefix
                                              ,op1 ,op2))))
           (regular-2byte-sse-inst-imm (name prefix op1 op2)
             `(define-instruction ,name (segment dst src imm)
                ,@(2byte-sse-inst-printer-list
                    '2byte-xmm-xmm/mem prefix op1 op2
                    :more-fields '((imm nil :type 'imm-byte))
                    :printer `(:name :tab reg ", " reg/mem ", " imm))
                (:emitter
                 (aver (typep imm '(unsigned-byte 8)))
                 (emit-regular-2byte-sse-inst segment dst src ,prefix ,op1 ,op2
                                              :remaining-bytes 1)
                 (emit-byte segment imm)))))
  (regular-2byte-sse-inst pshufb #x66 #x38 #x00)
  (regular-2byte-sse-inst phaddw #x66 #x38 #x01)
  (regular-2byte-sse-inst phaddd #x66 #x38 #x02)
  (regular-2byte-sse-inst phaddsw #x66 #x38 #x03)
  (regular-2byte-sse-inst pmaddubsw #x66 #x38 #x04)
  (regular-2byte-sse-inst phsubw #x66 #x38 #x05)
  (regular-2byte-sse-inst phsubd #x66 #x38 #x06)
  (regular-2byte-sse-inst phsubsw #x66 #x38 #x07)
  (regular-2byte-sse-inst psignb #x66 #x38 #x08)
  (regular-2byte-sse-inst psignw #x66 #x38 #x09)
  (regular-2byte-sse-inst psignd #x66 #x38 #x0a)
  (regular-2byte-sse-inst pmulhrsw #x66 #x38 #x0b)

  (regular-2byte-sse-inst ptest #x66 #x38 #x17)
  (regular-2byte-sse-inst pabsb #x66 #x38 #x1c)
  (regular-2byte-sse-inst pabsw #x66 #x38 #x1d)
  (regular-2byte-sse-inst pabsd #x66 #x38 #x1e)

  (regular-2byte-sse-inst pmuldq #x66 #x38 #x28)
  (regular-2byte-sse-inst pcmpeqq #x66 #x38 #x29)
  (regular-2byte-sse-inst packusdw #x66 #x38 #x2b)

  (regular-2byte-sse-inst pcmpgtq #x66 #x38 #x37)
  (regular-2byte-sse-inst pminsb #x66 #x38 #x38)
  (regular-2byte-sse-inst pminsd #x66 #x38 #x39)
  (regular-2byte-sse-inst pminuw #x66 #x38 #x3a)
  (regular-2byte-sse-inst pminud #x66 #x38 #x3b)
  (regular-2byte-sse-inst pmaxsb #x66 #x38 #x3c)
  (regular-2byte-sse-inst pmaxsd #x66 #x38 #x3d)
  (regular-2byte-sse-inst pmaxuw #x66 #x38 #x3e)
  (regular-2byte-sse-inst pmaxud #x66 #x38 #x3f)

  (regular-2byte-sse-inst pmulld #x66 #x38 #x40)
  (regular-2byte-sse-inst phminposuw #x66 #x38 #x41)

  (regular-2byte-sse-inst aesimc #x66 #x38 #xdb)
  (regular-2byte-sse-inst aesenc #x66 #x38 #xdc)
  (regular-2byte-sse-inst aesenclast #x66 #x38 #xdd)
  (regular-2byte-sse-inst aesdec #x66 #x38 #xde)
  (regular-2byte-sse-inst aesdeclast #x66 #x38 #xdf)

  (regular-2byte-sse-inst pmovsxbw #x66 #x38 #x20)
  (regular-2byte-sse-inst pmovsxbd #x66 #x38 #x21)
  (regular-2byte-sse-inst pmovsxbq #x66 #x38 #x22)
  (regular-2byte-sse-inst pmovsxwd #x66 #x38 #x23)
  (regular-2byte-sse-inst pmovsxwq #x66 #x38 #x24)
  (regular-2byte-sse-inst pmovsxdq #x66 #x38 #x25)

  (regular-2byte-sse-inst pmovzxbw #x66 #x38 #x30)
  (regular-2byte-sse-inst pmovzxbd #x66 #x38 #x31)
  (regular-2byte-sse-inst pmovzxbq #x66 #x38 #x32)
  (regular-2byte-sse-inst pmovzxwd #x66 #x38 #x33)
  (regular-2byte-sse-inst pmovzxwq #x66 #x38 #x34)
  (regular-2byte-sse-inst pmovzxdq #x66 #x38 #x35)

  (regular-2byte-sse-inst-imm roundps #x66 #x3a #x08)
  (regular-2byte-sse-inst-imm roundpd #x66 #x3a #x09)
  (regular-2byte-sse-inst-imm roundss #x66 #x3a #x0a)
  (regular-2byte-sse-inst-imm roundsd #x66 #x3a #x0b)
  (regular-2byte-sse-inst-imm blendps #x66 #x3a #x0c)
  (regular-2byte-sse-inst-imm blendpd #x66 #x3a #x0d)
  (regular-2byte-sse-inst-imm pblendw #x66 #x3a #x0e)
  (regular-2byte-sse-inst-imm palignr #x66 #x3a #x0f)
  (regular-2byte-sse-inst-imm dpps    #x66 #x3a #x40)
  (regular-2byte-sse-inst-imm dppd    #x66 #x3a #x41)

  (regular-2byte-sse-inst-imm mpsadbw #x66 #x3a #x42)
  (regular-2byte-sse-inst-imm pclmulqdq #x66 #x3a #x44)

  (regular-2byte-sse-inst-imm pcmpestrm #x66 #x3a #x60)
  (regular-2byte-sse-inst-imm pcmpestri #x66 #x3a #x61)
  (regular-2byte-sse-inst-imm pcmpistrm #x66 #x3a #x62)
  (regular-2byte-sse-inst-imm pcmpistri #x66 #x3a #x63)

  (regular-2byte-sse-inst-imm aeskeygenassist #x66 #x3a #xdf))

;;; Other SSE instructions

;; Instructions implicitly using XMM0 as a mask
(macrolet ((define-sse-inst-implicit-mask (name prefix op1 op2)
             `(define-instruction ,name (segment dst src mask)
                ,@(2byte-sse-inst-printer-list
                    '2byte-xmm-xmm/mem prefix op1 op2
                    :printer '(:name :tab reg ", " reg/mem ", XMM0"))
                (:emitter
                 (aver (xmm-register-p dst))
                 (aver (and (xmm-register-p mask) (= (tn-offset mask) 0)))
                 (emit-regular-2byte-sse-inst segment dst src ,prefix
                                              ,op1 ,op2)))))

  (define-sse-inst-implicit-mask pblendvb #x66 #x38 #x10)
  (define-sse-inst-implicit-mask blendvps #x66 #x38 #x14)
  (define-sse-inst-implicit-mask blendvpd #x66 #x38 #x15))

(define-instruction movnti (segment dst src)
  (:printer ext-reg-reg/mem-no-width ((op #xc3)) '(:name :tab reg/mem ", " reg))
  (:emitter
   (aver (not (register-p dst)))
   (aver (gpr-p src))
   (maybe-emit-rex-for-ea segment dst src)
   (emit-byte segment #x0f)
   (emit-byte segment #xc3)
   (emit-ea segment dst (reg-tn-encoding src))))

(flet ((emit* (segment opcode subcode src)
         (aver (not (register-p src)))
         (aver (eq (operand-size src) :byte))
         (aver subcode)
         (maybe-emit-rex-for-ea segment src nil)
         (emit-byte segment #x0f)
         (emit-byte segment opcode)
         (emit-ea segment src subcode)))

  (define-instruction prefetch (segment type src)
    (:printer ext-reg/mem-no-width ((op '(#x18 0)))
              '("PREFETCHNTA" :tab reg/mem))
    (:printer ext-reg/mem-no-width ((op '(#x18 1)))
              '("PREFETCHT0" :tab reg/mem))
    (:printer ext-reg/mem-no-width ((op '(#x18 2)))
              '("PREFETCHT1" :tab reg/mem))
    (:printer ext-reg/mem-no-width ((op '(#x18 3)))
              '("PREFETCHT2" :tab reg/mem))
    (:emitter (emit* segment #x18 (position type #(:nta :t0 :t1 :t2)) src)))

  (define-instruction clflush (segment src)
    (:printer ext-reg/mem-no-width ((op '(#xae 7))))
    (:emitter (emit* segment #xae 7 src))))

(macrolet ((define-fence-instruction (name last-byte)
               `(define-instruction ,name (segment)
                  (:printer three-bytes ((op '(#x0f #xae ,last-byte))))
                  (:emitter (emit-bytes segment #x0f #xae ,last-byte)))))
  (define-fence-instruction lfence #xE8)
  (define-fence-instruction mfence #xF0)
  (define-fence-instruction sfence #xF8))

(define-instruction pause (segment)
  (:printer two-bytes ((op '(#xf3 #x90))))
  (:emitter (emit-bytes segment #xf3 #x90)))

(flet ((emit* (segment ea subcode)
         (aver (not (register-p ea)))
         (aver (eq (operand-size ea) :dword))
         (maybe-emit-rex-for-ea segment ea nil)
         (emit-byte segment #x0f)
         (emit-byte segment #xae)
         (emit-ea segment ea subcode)))

  (define-instruction ldmxcsr (segment src)
    (:printer ext-reg/mem-no-width ((op '(#xae 2))))
    (:emitter (emit* segment src 2)))

  (define-instruction stmxcsr (segment dst)
    (:printer ext-reg/mem-no-width ((op '(#xae 3))))
    (:emitter (emit* segment dst 3))))

(define-instruction popcnt (segment dst src)
  (:printer f3-escape-reg-reg/mem ((op #xB8)))
  (:printer rex-f3-escape-reg-reg/mem ((op #xB8)))
  (:emitter
   (aver (gpr-p dst))
   (aver (and (gpr-p dst) (not (eq (operand-size dst) :byte))))
   (aver (not (eq (operand-size src) :byte)))
   (emit-sse-inst segment dst src #xf3 #xb8)))

(define-instruction crc32 (segment dst src)
  ;; The low bit of the final opcode byte sets the source size.
  ;; REX.W bit sets the destination size. can't have #x66 prefix and REX.W = 1.
  (:printer ext-2byte-prefix-reg-reg/mem
            ((prefix #xf2) (op1 #x38)
             (op2 #b1111000 :field (byte 7 25)) ; #xF0 ignoring the low bit
             (src-width nil :field (byte 1 24) :prefilter #'prefilter-width)
             (reg nil :printer #'print-d/q-word-reg)))
  (:printer ext-rex-2byte-prefix-reg-reg/mem
            ((prefix #xf2) (op1 #x38)
             (op2 #b1111000 :field (byte 7 33)) ; ditto
             (src-width nil :field (byte 1 32) :prefilter #'prefilter-width)
             (reg nil :printer #'print-d/q-word-reg)))
  (:emitter
   (let ((dst-size (operand-size dst))
         (src-size (operand-size src)))
     ;; The following operand size combinations are possible:
     ;;   dst = r32, src = r/m{8, 16, 32}
     ;;   dst = r64, src = r/m{8, 64}
     (aver (and (gpr-p dst)
                (memq src-size (case dst-size
                                 (:dword '(:byte :word :dword))
                                 (:qword '(:byte :qword))))))
     (maybe-emit-operand-size-prefix segment src-size)
     (emit-sse-inst-2byte segment dst src #xf2 #x38
                          (if (eq src-size :byte) #xf0 #xf1)
                          ;; :OPERAND-SIZE is ordinarily determined
                          ;; from 'src', so override it to use 'dst'.
                          :operand-size dst-size))))

;;;; Miscellany

(define-instruction cpuid (segment)
  (:printer two-bytes ((op '(#x0F #xA2))))
  (:emitter (emit-bytes segment #x0F #xA2)))

(define-instruction rdtsc (segment)
  (:printer two-bytes ((op '(#x0F #x31))))
  (:emitter (emit-bytes segment #x0f #x31)))

;;;; Intel TSX - some user library (STMX) used to define these,
;;;; but it's not really supported and they actually belong here.

(define-instruction-format
    (xbegin 48 :default-printer '(:name :tab label))
  (op :fields (list (byte 8 0) (byte 8 8)) :value '(#xc7 #xf8))
  (label :field (byte 32 16) :type 'displacement))

(define-instruction-format
    (xabort 24 :default-printer '(:name :tab imm))
  (op :fields (list (byte 8 0) (byte 8 8)) :value '(#xc6 #xf8))
  (imm :field (byte 8 16)))

(define-instruction xbegin (segment &optional where)
  (:printer xbegin ())
  (:emitter
   (emit-bytes segment #xc7 #xf8)
   (if where
       ;; emit 32-bit, signed relative offset for where
       (emit-dword-displacement-backpatch segment where)
       ;; nowhere to jump: simply jump to the next instruction
       (emit-dword segment 0))))

(define-instruction xend (segment)
  (:printer three-bytes ((op '(#x0f #x01 #xd5))))
  (:emitter (emit-bytes segment #x0f #x01 #xd5)))

(define-instruction xabort (segment reason)
  (:printer xabort ())
  (:emitter
   (aver (<= 0 reason #xff))
   (emit-bytes segment #xc6 #xf8 reason)))

(define-instruction xtest (segment)
  (:printer three-bytes ((op '(#x0f #x01 #xd6))))
  (:emitter (emit-bytes segment #x0f #x01 #xd6)))

(define-instruction xacquire (segment) ;; same prefix byte as repne/repnz
  (:emitter
   (emit-byte segment #xf2)))

(define-instruction xrelease (segment) ;; same prefix byte as rep/repe/repz
  (:emitter
   (emit-byte segment #xf3)))

;;;; Late VM definitions

(defun canonicalize-inline-constant (constant &aux (alignedp nil))
  (let ((first (car constant)))
    (when (eql first :aligned)
      (setf alignedp t)
      (pop constant)
      (setf first (car constant)))
    (typecase first
      (single-float (setf constant (list :single-float first)))
      (double-float (setf constant (list :double-float first)))
      .
      #+sb-xc-host
      ((complex
        ;; It's an error (perhaps) on the host to use simd-pack type.
        ;; [and btw it's disconcerting that this isn't an ETYPECASE.]
        (error "xc-host can't reference complex float")))
      #-sb-xc-host
      (((complex single-float)
        (setf constant (list :complex-single-float first)))
       ((complex double-float)
        (setf constant (list :complex-double-float first)))
       #!+sb-simd-pack
       (simd-pack
        (setq constant
              (list :sse (logior (%simd-pack-low first)
                                 (ash (%simd-pack-high first) 64))))))))
  (destructuring-bind (type value) constant
    (ecase type
      ((:byte :word :dword :qword)
         (aver (integerp value))
         (cons type value))
      ((:base-char)
         #!+sb-unicode (aver (typep value 'base-char))
         (cons :byte (char-code value)))
      ((:character)
         (aver (characterp value))
         (cons :dword (char-code value)))
      ((:single-float)
         (aver (typep value 'single-float))
         (cons (if alignedp :oword :dword)
               (ldb (byte 32 0) (single-float-bits value))))
      ((:double-float)
         (aver (typep value 'double-float))
         (cons (if alignedp :oword :qword)
               (ldb (byte 64 0) (logior (ash (double-float-high-bits value) 32)
                                        (double-float-low-bits value)))))
      ((:complex-single-float)
         (aver (typep value '(complex single-float)))
         (cons (if alignedp :oword :qword)
               (ldb (byte 64 0)
                    (logior (ash (single-float-bits (imagpart value)) 32)
                            (ldb (byte 32 0)
                                 (single-float-bits (realpart value)))))))
      ((:oword :sse)
         (aver (integerp value))
         (cons :oword value))
      ((:complex-double-float)
         (aver (typep value '(complex double-float)))
         (cons :oword
               (logior (ash (double-float-high-bits (imagpart value)) 96)
                       (ash (double-float-low-bits (imagpart value)) 64)
                       (ash (ldb (byte 32 0)
                                 (double-float-high-bits (realpart value)))
                            32)
                       (double-float-low-bits (realpart value))))))))

(defun inline-constant-value (constant)
  (let ((label (gen-label))
        (size  (ecase (car constant)
                 ((:byte :word :dword :qword) (car constant))
                 ((:oword) :qword))))
    (values label (rip-relative-ea size label))))

(defun sort-inline-constants (constants)
  (stable-sort constants #'> :key (lambda (constant)
                                    (size-nbyte (caar constant)))))

(defun emit-inline-constant (section constant label)
  (let ((size (size-nbyte (car constant))))
    (emit section
          `(.align ,(integer-length (1- size)))
          label
          ;; Could add pseudo-ops for .WORD, .INT, .QUAD, .OCTA just like gcc has.
          ;; But it works fine to emit as a sequence of bytes
          `(.byte ,@(let ((val (cdr constant)))
                      (loop repeat size
                            collect (prog1 (ldb (byte 8 0) val)
                                      (setf val (ash val -8)))))))))

(defun sb!assem::%mark-used-labels (operand)
  (when (typep operand 'ea)
    (let ((disp (ea-disp operand)))
      (typecase disp
       (label
        (setf (label-usedp disp) t))
       (label+addend
        (setf (label-usedp (label+addend-label disp)) t))))))

(defun sb!c::branch-opcode-p (mnemonic)
  (member mnemonic (load-time-value
                    (mapcar #'sb!assem::op-encoder-name
                            '(call ret jmp jrcxz break int iret
                              loop loopz loopnz syscall
                              byte word dword)) ; unexplained phenomena
                    t)))

;; Replace the INST-INDEXth element in INST-BUFFER with an instruction
;; to store a coverage mark in the OFFSETth byte beyond LABEL.
(defun sb!c::replace-coverage-instruction (inst-buffer inst-index label offset)
  (setf (svref inst-buffer inst-index)
        `(mov ,(rip-relative-ea :byte label offset) 1)))
