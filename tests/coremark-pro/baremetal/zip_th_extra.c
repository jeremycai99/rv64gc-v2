/*
 * zip_th_extra.c — additional th_* stubs needed by zlib-1.2.8's zutil.c.
 *
 * th_stubs.c provides th_calloc(n, size) but not th_calloc_x().
 * th_lib.h #defines:
 *   th_calloc(nmemb, size) -> th_calloc_x(nmemb, size, __FILE__, __LINE__)
 * so zutil.c (which includes zutil.h -> th_lib.h) needs th_calloc_x.
 *
 * Also provide th_vfprintf used if DEBUG is on (it's off for us, but the
 * symbol is referenced in zutil.h via the HAVE_FILEIO path in th_file.h).
 */

#include <stddef.h>
#include <stdlib.h>
#include <stdarg.h>

/* th_calloc_x: called by th_calloc macro expansion inside zutil.c */
void *th_calloc_x(size_t nmemb, size_t size, const char *file, int line) {
    (void)file; (void)line;
    return calloc(nmemb, size);
}

/* th_vfprintf: declared in th_file.h; may be referenced even if not called */
int th_vfprintf(void *fp, const char *fmt, va_list ap) {
    (void)fp; (void)fmt; (void)ap;
    return 0;
}

/* th_clearerr: declared in th_file.h */
void th_clearerr(void *fp) { (void)fp; }

/* th_fscanf / th_vfscanf / th_sscanf: declared in th_file.h */
int th_fscanf(void *stream, const char *format, ...) {
    (void)stream; (void)format; return -1;
}
int th_vfscanf(void *stream, const char *format, va_list ap) {
    (void)stream; (void)format; (void)ap; return -1;
}
int th_sscanf(const char *str, const char *format, ...) {
    (void)str; (void)format; return -1;
}

/* th_getcwd / th_getwd / th_chdir: declared in th_file.h */
char *th_getcwd(char *buf, size_t size) { (void)buf; (void)size; return NULL; }
char *th_getwd(char *buf) { (void)buf; return NULL; }
int   th_chdir(const char *path) { (void)path; return -1; }

/* th_stat / th_lstat / th_fstat */
int th_stat(const char *path, void *buf) { (void)path; (void)buf; return -1; }
int th_lstat(const char *path, void *buf) { (void)path; (void)buf; return -1; }
int th_fstat(int fd, void *buf) { (void)fd; (void)buf; return -1; }

/* th_rename / th_ungetc / th_mktemp */
int   th_rename(const char *old, const char *nw) { (void)old; (void)nw; return -1; }
int   th_ungetc(int c, void *fp) { (void)c; (void)fp; return -1; }
char *th_mktemp(char *tmpl) { (void)tmpl; return NULL; }

/* th_fcreate / th_fdopen / th_freopen / th_tmpfile */
void *th_fcreate(const char *f, const char *m, char *d, size_t s)
    { (void)f; (void)m; (void)d; (void)s; return NULL; }
void *th_fdopen(int fd, const char *mode) { (void)fd; (void)mode; return NULL; }
void *th_freopen(const char *f, const char *m, void *fp)
    { (void)f; (void)m; (void)fp; return NULL; }
void *th_tmpfile(void) { return NULL; }

/* get_auto_data_* (declared in th_file.h) */
void get_auto_data_int(char *fname, int **out, int *numread)
    { (void)fname; *out = NULL; *numread = 0; }
void get_auto_data_dbl(char *fname, double **out, int *numread)
    { (void)fname; *out = NULL; *numread = 0; }
void get_auto_data_byte(char *fname, unsigned char **out, int *numread)
    { (void)fname; *out = NULL; *numread = 0; }
