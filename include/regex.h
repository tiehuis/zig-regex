#include <stdbool.h>

typedef struct zre_regex zre_regex;

zre_regex *zre_compile(const char *input);
bool zre_match(zre_regex *re, const char *input);
bool zre_partial_match(zre_regex *re, const char *input);
void zre_deinit(zre_regex *re);
