#include "shim.h"

#include <math.h>
#include <mupdf/fitz.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct doc {
    fz_context *ctx;
    fz_document *document;
    int page_count;
    // Set by the first doc_outline call that loads the outline or finds it
    // unreadable, to DOC_OK or DOC_E_OUTLINE. Later calls return it without
    // parsing again. The items' titles point into the outline tree, so both
    // live until doc_close.
    int outline_loaded;
    int outline_status;
    fz_outline *outline;
    doc_outline_item *outline_items;
    int outline_count;
    // The structured text of page text_page, or NULL. One page is enough:
    // a selection never spans pages.
    fz_stext_page *text;
    int text_page;
};

// rdr owns the terminal while it runs, and MuPDF's default handlers would
// print warnings over the alternate screen.
static void discard(void *user, const char *message) {
    (void)user;
    (void)message;
}

static void set_message(char *message, size_t message_len, const char *text) {
    if (message_len > 0) snprintf(message, message_len, "%s", text);
}

static void drop(fz_context *ctx, fz_document *document) {
    fz_drop_document(ctx, document);
    fz_drop_context(ctx);
}

int doc_open(const char *path, doc **out, int *page_count_out, char *message, size_t message_len) {
    *out = NULL;
    *page_count_out = 0;
    set_message(message, message_len, "");

    fz_context *ctx = fz_new_context(NULL, NULL, FZ_STORE_DEFAULT);
    if (!ctx) {
        set_message(message, message_len, "cannot create MuPDF context");
        return DOC_E_NOMEM;
    }
    fz_set_error_callback(ctx, discard, NULL);
    fz_set_warning_callback(ctx, discard, NULL);

    // Volatile: written inside fz_try and read after a possible longjmp.
    fz_document *volatile document = NULL;
    volatile int page_count = 0;
    fz_try(ctx) {
        fz_register_document_handlers(ctx);
        document = fz_open_document(ctx, path);
        page_count = fz_count_pages(ctx, document);
    }
    fz_catch(ctx) {
        set_message(message, message_len, fz_caught_message(ctx));
        fz_ignore_error(ctx);
        drop(ctx, document);
        return DOC_E_OPEN;
    }
    if (page_count < 1) {
        set_message(message, message_len, "document has no pages");
        drop(ctx, document);
        return DOC_E_OPEN;
    }

    doc *d = malloc(sizeof *d);
    if (!d) {
        set_message(message, message_len, "out of memory");
        drop(ctx, document);
        return DOC_E_NOMEM;
    }
    *d = (doc){.ctx = ctx, .document = document, .page_count = page_count};
    *out = d;
    *page_count_out = page_count;
    return DOC_OK;
}

void doc_close(doc *d) {
    fz_drop_stext_page(d->ctx, d->text);
    free(d->outline_items);
    fz_drop_outline(d->ctx, d->outline);
    drop(d->ctx, d->document);
    free(d);
}

int doc_page_size(doc *d, int page, float *w_pt, float *h_pt) {
    fz_context *ctx = d->ctx;
    fz_page *volatile loaded = NULL;
    fz_rect bounds = fz_empty_rect;
    fz_try(ctx) {
        loaded = fz_load_page(ctx, d->document, page);
        bounds = fz_bound_page(ctx, loaded);
    }
    fz_always(ctx) {
        fz_drop_page(ctx, loaded);
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        return DOC_E_PAGE;
    }

    float w = bounds.x1 - bounds.x0;
    float h = bounds.y1 - bounds.y0;
    if (!(w > 0) || !(h > 0)) return DOC_E_PAGE;
    *w_pt = w;
    *h_pt = h;
    return DOC_OK;
}

// The page an entry points to, or -1. Can throw: resolving a link may load
// part of the document.
static int outline_page(fz_context *ctx, doc *d, const fz_outline *node, float *y) {
    fz_location location = node->page;
    float x = 0;
    *y = node->y;
    if (location.page < 0 && node->uri && !fz_is_external_link(ctx, node->uri)) {
        location = fz_resolve_link(ctx, d->document, node->uri, &x, y);
    }
    if (location.page < 0) return -1;
    int page = fz_page_number_from_location(ctx, d->document, location);
    return page >= 0 && page < d->page_count ? page : -1;
}

// Walks the tree in pre-order with an explicit stack, so a deep outline
// cannot overflow the C stack. Counts the entries, and fills items too when
// it is not NULL. Can throw only when filling.
static int walk_outline(fz_context *ctx, doc *d, fz_outline *root, doc_outline_item *items) {
    // pending[i] is the next sibling of the open ancestor at depth i.
    fz_outline *pending[DOC_OUTLINE_DEPTH_MAX];
    int depth = 0;
    int count = 0;
    fz_outline *node = root;
    while (node && count < DOC_OUTLINE_ITEMS_MAX) {
        if (items) {
            float y = 0;
            int page = outline_page(ctx, d, node, &y);
            items[count] = (doc_outline_item){
                .title = node->title ? node->title : "",
                .page = page,
                // NaN, infinite and negative positions all mean the top.
                .y = page >= 0 && isfinite(y) && y > 0 ? y : 0,
                .depth = depth,
                .open = node->is_open,
            };
        }
        count++;
        if (node->down && depth + 1 < DOC_OUTLINE_DEPTH_MAX) {
            pending[depth] = node->next;
            depth++;
            node = node->down;
        } else {
            node = node->next;
        }
        while (!node && depth > 0) {
            depth--;
            node = pending[depth];
        }
    }
    return count;
}

static int load_outline(doc *d) {
    fz_context *ctx = d->ctx;
    fz_outline *volatile outline = NULL;
    fz_try(ctx) {
        outline = fz_load_outline(ctx, d->document);
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        return DOC_E_OUTLINE;
    }

    int count = walk_outline(ctx, d, outline, NULL);
    doc_outline_item *items = NULL;
    if (count > 0) {
        items = calloc((size_t)count, sizeof *items);
        if (!items) {
            fz_drop_outline(ctx, outline);
            return DOC_E_NOMEM;
        }
        volatile int filled = 0;
        fz_try(ctx) {
            filled = walk_outline(ctx, d, outline, items);
        }
        fz_catch(ctx) {
            fz_ignore_error(ctx);
            free(items);
            fz_drop_outline(ctx, outline);
            return DOC_E_OUTLINE;
        }
        // Both walks see the same tree and stop at the same cap.
        if (filled != count) {
            free(items);
            fz_drop_outline(ctx, outline);
            return DOC_E_OUTLINE;
        }
    }
    d->outline = outline;
    d->outline_items = items;
    d->outline_count = count;
    return DOC_OK;
}

int doc_outline(doc *d, doc_outline_item **items, int *count) {
    if (!d->outline_loaded) {
        int status = load_outline(d);
        // Running out of memory may pass, so only that is retried. A broken
        // outline stays broken, and parsing it again on every call would
        // stall the viewer each time.
        if (status == DOC_E_NOMEM) return status;
        d->outline_loaded = 1;
        d->outline_status = status;
    }
    if (d->outline_status != DOC_OK) return d->outline_status;
    *items = d->outline_items;
    *count = d->outline_count;
    return DOC_OK;
}

int doc_render(doc *d, int page, float scale, doc_pixmap *out) {
    fz_context *ctx = d->ctx;
    fz_page *volatile loaded = NULL;
    fz_pixmap *volatile rendered = NULL;
    fz_try(ctx) {
        loaded = fz_load_page(ctx, d->document, page);
        rendered = fz_new_pixmap_from_page(ctx, loaded, fz_scale(scale, scale),
                                           fz_device_rgb(ctx), 0);
    }
    fz_always(ctx) {
        fz_drop_page(ctx, loaded);
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        return DOC_E_RENDER;
    }

    fz_pixmap *pixmap = rendered;
    int w = fz_pixmap_width(ctx, pixmap);
    int h = fz_pixmap_height(ctx, pixmap);
    ptrdiff_t stride = fz_pixmap_stride(ctx, pixmap);
    size_t row_len = (size_t)w * 3;
    if (w < 1 || h < 1 || fz_pixmap_components(ctx, pixmap) != 3 ||
        stride < (ptrdiff_t)row_len) {
        fz_drop_pixmap(ctx, pixmap);
        return DOC_E_RENDER;
    }

    // Drop any row padding in place. Row y moves from y * stride down to
    // y * row_len, which never overlaps a row that has not moved yet.
    unsigned char *samples = fz_pixmap_samples(ctx, pixmap);
    if ((size_t)stride != row_len) {
        for (size_t y = 1; y < (size_t)h; y++) {
            memmove(samples + y * row_len, samples + y * (size_t)stride, row_len);
        }
    }

    *out = (doc_pixmap){.samples = samples, .w = w, .h = h, .owner = pixmap};
    return DOC_OK;
}

void doc_pixmap_drop(doc *d, doc_pixmap *pixmap) {
    fz_drop_pixmap(d->ctx, pixmap->owner);
    *pixmap = (doc_pixmap){0};
}

// Makes d->text the structured text of page. The old page's text is dropped
// first, so a failure leaves no text loaded rather than the wrong page's.
static int load_text(doc *d, int page) {
    if (d->text && d->text_page == page) return DOC_OK;
    fz_context *ctx = d->ctx;
    fz_drop_stext_page(ctx, d->text);
    d->text = NULL;

    fz_page *volatile loaded = NULL;
    fz_stext_page *volatile text = NULL;
    // Default flags: ligatures are split and whitespace becomes spaces,
    // which is what a pasted selection should contain.
    fz_stext_options options = {0};
    fz_try(ctx) {
        loaded = fz_load_page(ctx, d->document, page);
        text = fz_new_stext_page_from_page(ctx, loaded, &options);
    }
    fz_always(ctx) {
        fz_drop_page(ctx, loaded);
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        return DOC_E_TEXT;
    }
    d->text = text;
    d->text_page = page;
    return DOC_OK;
}

// Structured text uses the page's own coordinates, whose origin is the
// mediabox corner rather than (0, 0).
static fz_point to_text(const doc *d, doc_point p) {
    return fz_make_point(d->text->mediabox.x0 + p.x, d->text->mediabox.y0 + p.y);
}

int doc_highlight(doc *d, int page, doc_point a, doc_point b, doc_rect *rects, int rects_max, int *count) {
    *count = 0;
    int status = load_text(d, page);
    if (status != DOC_OK) return status;

    // Bounded by the caller's array, so this stays on the stack. MuPDF
    // writes at most rects_max quads.
    enum { QUADS_MAX = 1024 };
    fz_quad quads[QUADS_MAX];
    int quads_max = rects_max < QUADS_MAX ? rects_max : QUADS_MAX;
    // fz_highlight_selection walks the text without allocating, so it
    // cannot throw.
    int found = fz_highlight_selection(d->ctx, d->text, to_text(d, a), to_text(d, b), quads, quads_max);

    float x0 = d->text->mediabox.x0;
    float y0 = d->text->mediabox.y0;
    int written = 0;
    for (int i = 0; i < found && i < quads_max; i++) {
        fz_rect r = fz_rect_from_quad(quads[i]);
        // A degenerate font matrix can yield NaN or infinite corners.
        if (!isfinite(r.x0) || !isfinite(r.y0) || !isfinite(r.x1) || !isfinite(r.y1)) continue;
        if (!(r.x0 <= r.x1) || !(r.y0 <= r.y1)) continue;
        rects[written++] = (doc_rect){.x0 = r.x0 - x0, .y0 = r.y0 - y0, .x1 = r.x1 - x0, .y1 = r.y1 - y0};
    }
    *count = written;
    return DOC_OK;
}

int doc_copy(doc *d, int page, doc_point a, doc_point b, char **text) {
    *text = NULL;
    int status = load_text(d, page);
    if (status != DOC_OK) return status;

    fz_context *ctx = d->ctx;
    char *volatile copied = NULL;
    fz_try(ctx) {
        copied = fz_copy_selection(ctx, d->text, to_text(d, a), to_text(d, b), 0);
    }
    fz_catch(ctx) {
        fz_ignore_error(ctx);
        return DOC_E_TEXT;
    }
    if (!copied) return DOC_E_TEXT;
    *text = copied;
    return DOC_OK;
}

void doc_text_drop(doc *d, char *text) {
    fz_free(d->ctx, text);
}
