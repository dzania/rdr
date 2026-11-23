// C wrapper around MuPDF for rdr.
//
// MuPDF reports errors by longjmp out of fz_try blocks, and fz_new_context is
// a macro. Neither can be called from Zig, so every MuPDF call that can throw
// is made here, and failures come back as a negative DOC_E_* status. Callers
// pass valid pages and positive scales; the Zig side asserts both.
#ifndef RDR_SHIM_H
#define RDR_SHIM_H

#include <stddef.h>

enum {
    DOC_OK = 0,
    DOC_E_NOMEM = -1,
    DOC_E_OPEN = -2,
    DOC_E_PAGE = -3,
    DOC_E_RENDER = -4,
    DOC_E_OUTLINE = -5,
    DOC_E_TEXT = -6,
};

// Outline entries nested deeper than this are left out, with their children.
#define DOC_OUTLINE_DEPTH_MAX 32
// Entries after this many are left out. Real tables of contents are far
// smaller; the cap bounds memory for a malformed or hostile document.
#define DOC_OUTLINE_ITEMS_MAX 65536

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

// One table of contents entry. Entries come in reading order (a pre-order
// walk of the tree): depth is 0 for the first entry and grows by at most 1
// from one entry to the next, so an entry's children are the deeper entries
// right after it.
typedef struct doc_outline_item {
    // NUL-terminated UTF-8, never NULL. May contain control characters.
    const char *title;
    // 0-based page index below the page count, or -1 when the entry does
    // not point into this document.
    int page;
    // Target position from the top of the page, in points; 0 if unknown.
    float y;
    // 0 <= depth < DOC_OUTLINE_DEPTH_MAX.
    int depth;
    // Nonzero if the document wants the entry expanded. The viewer then
    // toggles it: the shim never reads it back.
    int open;
} doc_outline_item;

// The table of contents, loaded on the first call and owned by d until
// doc_close. A document without one yields *count = 0 and *items = NULL.
// DOC_E_OUTLINE is remembered: later calls return it without parsing the
// outline again. DOC_E_NOMEM is not, so a later call tries again.
int doc_outline(doc *d, doc_outline_item **items, int *count);

int doc_render(doc *d, int page, float scale, doc_pixmap *out);
void doc_pixmap_drop(doc *d, doc_pixmap *pixmap);

// Text selection. Points and rectangles are in points (1/72 inch) from the
// top-left corner of the page, the space doc_page_size measures, so the
// caller can map them to a page image by multiplying by its render scale.
// The page's text is extracted by the first call for that page and kept
// until a call for another page or doc_close. Callers pass finite points.
typedef struct doc_point {
    float x;
    float y;
} doc_point;

// x0 <= x1 and y0 <= y1, all finite.
typedef struct doc_rect {
    float x0;
    float y0;
    float x1;
    float y1;
} doc_rect;

// Rectangles covering the text from a to b in reading order, roughly one
// per line, written to rects. Sets *count to at most rects_max; a selection
// that needs more is cut short. rects_max must be positive.
int doc_highlight(doc *d, int page, doc_point a, doc_point b, doc_rect *rects, int rects_max, int *count);

// The text from a to b in reading order, as NUL-terminated UTF-8 with "\n"
// line endings, never NULL. Empty when the selection holds no text.
// Release with doc_text_drop.
int doc_copy(doc *d, int page, doc_point a, doc_point b, char **text);
void doc_text_drop(doc *d, char *text);

#endif
