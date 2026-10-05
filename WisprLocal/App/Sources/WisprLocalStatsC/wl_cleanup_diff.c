// Word-level cleanup diff, in C so it stays fast in unoptimised (debug/test) builds too.
// The rules are documented on `CleanupDiff` in WisprLocalCore/Stats/CleanupDiff.swift.
#include "wl_cleanup_diff.h"
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint64_t core;     // FNV-1a of lowercased letters/digits (bytes >= 0x80 count as letters)
    uint64_t surface;  // FNV-1a of the token's bytes as typed
    int has_digit;
} wl_tok;

static const uint64_t FNV_OFFSET = 0xcbf29ce484222325ULL;
static const uint64_t FNV_PRIME = 0x00000100000001b3ULL;

static int is_space(uint8_t b) { return b == 32 || (b >= 9 && b <= 13); }

static uint64_t hash_str(const char *s) {
    uint64_t h = FNV_OFFSET;
    for (; *s; s++) h = (h ^ (uint8_t)*s) * FNV_PRIME;
    return h;
}

static const char *const FILLERS[] = {"um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "ahh", "hmm", "hmmm",
                                      "like", "well", "so"};
enum { N_FILLERS = sizeof(FILLERS) / sizeof(FILLERS[0]) };

static int is_filler(uint64_t core) {
    for (int i = 0; i < N_FILLERS; i++) if (hash_str(FILLERS[i]) == core) return 1;
    return 0;
}

/// Tokenises into `out` (capacity >= len / 2 + 1); returns token count.
static size_t tokenize(const uint8_t *s, size_t len, wl_tok *out, int64_t *newlines, int64_t *punct_only) {
    size_t n = 0;
    uint64_t core = FNV_OFFSET, surf = FNV_OFFSET;
    int core_len = 0, digit = 0, in_tok = 0;
    for (size_t p = 0; p <= len; p++) {
        uint8_t b = p < len ? s[p] : ' ';
        if (is_space(b)) {
            if (p < len && b == '\n') (*newlines)++;
            if (in_tok) {
                if (core_len > 0) { out[n].core = core; out[n].surface = surf; out[n].has_digit = digit; n++; }
                else (*punct_only)++;
                core = FNV_OFFSET; surf = FNV_OFFSET; core_len = 0; digit = 0; in_tok = 0;
            }
            continue;
        }
        in_tok = 1;
        surf = (surf ^ b) * FNV_PRIME;
        uint8_t c = (b >= 'A' && b <= 'Z') ? (uint8_t)(b + 32) : b;
        if ((c >= 'a' && c <= 'z') || c >= 0x80) { core = (core ^ c) * FNV_PRIME; core_len++; }
        else if (c >= '0' && c <= '9') { core = (core ^ c) * FNV_PRIME; core_len++; digit = 1; }
    }
    return n;
}

/// One hunk: A[d0, d1) removed and B[i0, i1) added between two aligned words.
static void classify(const wl_tok *A, size_t d0, size_t d1, const wl_tok *B, size_t i0, size_t i1, wl_cleanup_counts *c) {
    if (d0 == d1 && i0 == i1) return;
    const uint64_t you = hash_str("you"), know = hash_str("know");
    int64_t rest = 0;
    for (size_t k = d0; k < d1; k++) {
        if (A[k].core == you && k + 1 < d1 && A[k + 1].core == know) { c->fillers++; k++; continue; }
        if (is_filler(A[k].core)) c->fillers++; else rest++;
    }
    if (i0 == i1) { if (rest > 0) c->formatting++; return; }        // voice command / removed aside
    if (rest == 0) { c->formatting++; return; }                     // added list markers etc.
    for (size_t k = i0; k < i1; k++) if (B[k].has_digit) { c->formatting++; return; }  // number → digits
    c->dictionary++;
}

int64_t wl_word_count(const uint8_t *s, size_t len) {
    int64_t n = 0;
    int in_tok = 0;
    for (size_t i = 0; i < len; i++) {
        if (is_space(s[i])) in_tok = 0;
        else if (!in_tok) { in_tok = 1; n++; }
    }
    return n;
}

wl_cleanup_counts wl_cleanup_diff(const uint8_t *raw, size_t raw_len, const uint8_t *final, size_t final_len) {
    wl_cleanup_counts c = {0, 0, 0, 0};
    wl_tok abuf[256], bbuf[256];
    size_t acap = raw_len / 2 + 1, bcap = final_len / 2 + 1;
    wl_tok *a = acap <= 256 ? abuf : malloc(acap * sizeof(wl_tok));
    wl_tok *b = bcap <= 256 ? bbuf : malloc(bcap * sizeof(wl_tok));
    if (!a || !b) { if (a != abuf) free(a); if (b != bbuf) free(b); c.final_words = wl_word_count(final, final_len); return c; }
    int64_t anl = 0, ap = 0, bnl = 0, bp = 0;
    size_t na = tokenize(raw, raw_len, a, &anl, &ap);
    size_t nb = tokenize(final, final_len, b, &bnl, &bp);
    c.final_words = (int64_t)nb + bp;
    c.formatting += (bnl > anl ? bnl - anl : 0) + (bp > ap ? bp - ap : 0);

    // Common prefix / suffix by core; surface changes there are formatting.
    size_t lo = 0;
    while (lo < na && lo < nb && a[lo].core == b[lo].core) { if (a[lo].surface != b[lo].surface) c.formatting++; lo++; }
    size_t ha = na, hb = nb;
    while (ha > lo && hb > lo && a[ha - 1].core == b[hb - 1].core) {
        if (a[ha - 1].surface != b[hb - 1].surface) c.formatting++;
        ha--; hb--;
    }
    size_t n = ha - lo, m = hb - lo;
    const wl_tok *A = a + lo, *B = b + lo;
    if (n == 0 || m == 0 || n * m > 250000) {
        classify(A, 0, n, B, 0, m, &c);
    } else {
        size_t w = m + 1;
        int32_t *dp = calloc((n + 1) * w, sizeof(int32_t));
        if (!dp) {
            classify(A, 0, n, B, 0, m, &c);
        } else {
            for (size_t i = n; i-- > 0;) {
                for (size_t j = m; j-- > 0;) {
                    size_t k = i * w + j;
                    if (A[i].core == B[j].core) dp[k] = dp[k + w + 1] + 1;
                    else dp[k] = dp[k + w] > dp[k + 1] ? dp[k + w] : dp[k + 1];
                }
            }
            size_t i = 0, j = 0, i0 = 0, j0 = 0;
            while (i < n || j < m) {
                if (i < n && j < m && A[i].core == B[j].core) {
                    classify(A, i0, i, B, j0, j, &c);
                    if (A[i].surface != B[j].surface) c.formatting++;
                    i++; j++; i0 = i; j0 = j;
                } else if (j >= m || (i < n && dp[(i + 1) * w + j] >= dp[i * w + j + 1])) {
                    i++;
                } else {
                    j++;
                }
            }
            classify(A, i0, i, B, j0, j, &c);
            free(dp);
        }
    }
    if (a != abuf) free(a);
    if (b != bbuf) free(b);
    return c;
}
