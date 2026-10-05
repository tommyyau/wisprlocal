#ifndef WL_CLEANUP_DIFF_H
#define WL_CLEANUP_DIFF_H

#include <stddef.h>
#include <stdint.h>

/// Edits between heard (`raw`) and typed (`final`) text; see `CleanupDiff` (Swift) for the rules.
typedef struct {
    int64_t fillers;
    int64_t dictionary;
    int64_t formatting;
    /// Whitespace-separated words in `final`.
    int64_t final_words;
} wl_cleanup_counts;

/// Classifies the word-level diff of raw vs final. Pure; allocates only for long texts.
wl_cleanup_counts wl_cleanup_diff(const uint8_t *raw, size_t raw_len, const uint8_t *final, size_t final_len);

/// Whitespace-separated (ASCII whitespace) word count.
int64_t wl_word_count(const uint8_t *s, size_t len);

#endif
