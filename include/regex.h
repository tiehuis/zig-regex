#ifndef __ZRE_H__
#define __ZRE_H__

#include <stdbool.h>
#include <stddef.h>

typedef struct zre_regex_t zre_regex_t;
typedef struct zre_captures_t zre_captures_t;

typedef struct zre_captures_span_t {
  size_t lower;
  size_t upper;
} zre_captures_span_t;

extern zre_regex_t* zre_compile(const char* input);

extern bool zre_match(zre_regex_t* re, const char* input);

extern bool zre_partial_match(zre_regex_t* re, const char* input);

extern void zre_deinit(zre_regex_t* re);

extern zre_captures_t* zre_captures(zre_regex_t* re, const char* input);

extern size_t zre_captures_len(const zre_captures_t* cap);

extern const char* zre_captures_slice_at(const zre_captures_t* cap, size_t n);

extern bool zre_captures_bounds_at(const zre_captures_t* cap, zre_captures_span_t* sp, size_t n);

extern void zre_captures_deinit(zre_captures_t* cap);

#endif // __ZRE_H__
