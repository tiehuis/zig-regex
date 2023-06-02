#ifndef __ZRE_H__
#define __ZRE_H__

#include <stdbool.h>
#include <stddef.h>

typedef struct zre_regex zre_regex;
typedef struct zre_captures zre_captures;

typedef struct zre_captures_span {
  size_t lower;
  size_t upper;
} zre_captures_span;

extern zre_regex* zre_compile(const char* input);

extern bool zre_match(zre_regex* re, const char* input);

extern bool zre_partial_match(zre_regex* re, const char* input);

extern void zre_deinit(zre_regex* re);

extern zre_captures* zre_captures_all(zre_regex* re, const char* input);

extern size_t zre_captures_len(const zre_captures* cap);

extern const char* zre_captures_slice_at(const zre_captures* cap, size_t n, size_t* len);

extern bool zre_captures_bounds_at(const zre_captures* cap, zre_captures_span* sp, size_t n);

extern void zre_captures_deinit(zre_captures* cap);

#endif // __ZRE_H__
