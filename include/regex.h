#include <stdbool.h>

typedef struct zre_regex_t zre_regex_t;

zre_regex_t *zre_compile(const char *input);
bool zre_match(zre_regex_t *re, const char *input);
bool zre_partial_match(zre_regex_t *re, const char *input);
void zre_deinit(zre_regex_t *re);
