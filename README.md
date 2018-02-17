An automation-based regex implementation for [zig](http://ziglang.org/).

```
const debug = @import("std").debug;
const Regex = @import("regex.zig").Regex;

test "example" {
    var re = try Regex.compile(debug.global_allocator, "\\w+");

    debug.assert(try re.match("hej") == true);
}
```

See the following useful sources:
 - https://swtch.com/~rsc/regexp/
 - [Rust Regex Library](https://github.com/rust-lang/regex)
 - [Go Regex Library](https://github.com/golang/go/tree/master/src/regexp)
