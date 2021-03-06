/*
 * This software is part of the SBCL system. See the README file for
 * more information.
 *
 * This software is derived from the CMU CL system, which was
 * written at Carnegie Mellon University and released into the
 * public domain. The software is in the public domain and is
 * provided with absolutely no warranty. See the COPYING and CREDITS
 * files for more information.
 */

#ifndef _SEARCH_H_
#define _SEARCH_H_

extern lispobj* find_symbol(char*, char*, unsigned int*); // Find via package
extern struct symbol* lisp_symbol_from_tls_index(lispobj tls_index);
// Find via heap scan
extern boolean search_for_type(int type, lispobj **start, int *count);
extern lispobj* search_for_symbol(char *name, lispobj start, lispobj end);

#endif
