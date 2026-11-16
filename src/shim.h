// C wrapper around MuPDF for rdr.
//
// MuPDF reports errors by longjmp out of fz_try blocks, and fz_new_context is
// a macro. Neither can be called from Zig, so every MuPDF call that can throw
// is made here, and failures come back as a negative DOC_E_* status. Callers
// pass valid pages and positive scales; the Zig side asserts both.
#ifndef RDR_SHIM_H
#define RDR_SHIM_H

#include <stddef.h>

enum { DOC_OK = 0, DOC_E_NOMEM = -1, DOC_E_OPEN = -2, DOC_E_PAGE = -3, DOC_E_RENDER = -4 };

typedef struct doc doc;

// A rendered page: packed 8-bit RGB, 3 bytes per pixel, rows of exactly
// w * 3 bytes. Release with doc_pixmap_drop.
typedef struct doc_pixmap {
    const unsigned char *samples;
    int w;
    int h;
    void *owner;
} doc_pixmap;

// Sets *page_count to at least 1. On failure, writes MuPDF's reason to
// message as a NUL-terminated string, truncated to message_len bytes.
int doc_open(const char *path, doc **out, int *page_count, char *message, size_t message_len);
void doc_close(doc *d);

// Page size in points (1/72 inch).
int doc_page_size(doc *d, int page, float *w_pt, float *h_pt);

int doc_render(doc *d, int page, float scale, doc_pixmap *out);
void doc_pixmap_drop(doc *d, doc_pixmap *pixmap);

#endif
