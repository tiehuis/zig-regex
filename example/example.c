#include <stdio.h>
#include "regex.h"

int main() {
  zre_regex *re = zre_compile(".*world.*");
  if (!re) {
    printf("Regex compile error\n");
    return 1;
  }

  if (zre_match(re, "Hello world!"))
    printf("Match!\n");

  zre_deinit(re);
}
