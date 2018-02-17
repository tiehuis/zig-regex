An automation-based regex implementation for [zig](http://ziglang.org/).

Note: This is still a work in progress and many things still need to be done.

 [ ] - UTF-8 support
 [ ] - More tests (plus some automated tests/fuzzing)
 [ ] - Add a PikeVM implementation
 [ ] - Capture group support
 [ ] - Literal optimizations and just general performance improvements.

## Usage

```
const debug = @import("std").debug;
const Regex = @import("regex.zig").Regex;

test "example" {/
    var re = try Regex.compile(debug.global_allocator, "\\w+");

    debug.assert(try re.match("hej") == true);
}
```

## Api

```
fn compile(a: &Allocator, re: []const u8) !Regex
```

Compiles a regex string, returning any errors during parsing/compiling.

---

```
pub fn mustCompile(a: &Allocator, re: []const u8) Regex
```

Same as `compile`, but panics on any error.

---

```
pub fn match(re: &const Regex, input: []const u8) !bool
```

Match a compiled regex against some input. The input must be matched in its
entirety and from the first index.

---

```
pub fn partialMatch(re: &const Regex, input: []const u8) !bool
```

Match a compiled regex against some input. Unlike `match`, this matches the
leftmost and does not have to be anchored to the start of `input`.

---


## References

See the following useful sources:
 - https://swtch.com/~rsc/regexp/
 - [Rust Regex Library](https://github.com/rust-lang/regex)
 - [Go Regex Library](https://github.com/golang/go/tree/master/src/regexp)
