# tests/028-stdlib.pp — stdlib primitives + library files.
# The expected-output oracle (incl. argv/env/exit/file predicates, which need
# process-level setup) lives in tests/028-stdlib.sh.
load("stdlib/list.pp")
load("stdlib/string.pp")
load("stdlib/map.pp")

# ---- string primitives ----
print(number->string(42))
print(number->string(-7))
print(string->number("42"))
print(string->number("-13"))
print(string->number("3.5"))
print(string->number("nope"))
print(string-index("hello world", "world"))
print(string-index("hello", "zz"))
print(string-trim("  padded\n\t"))
print(string-sub("abcdef", 1, 3))
print(string-sub("abcdef", 0, 0))

# ---- stdlib/string.pp ----
print(string-join(",", list("a", "b", "c")))
print(string-join("-", nil))
print(starts-with?("foobar", "foo"))
print(starts-with?("foobar", "bar"))
print(ends-with?("foobar", "bar"))
print(ends-with?("foobar", "foo"))
print(lines("a\nb\nc\n"))

# ---- map primitives + stdlib/map.pp ----
let m = {:a -> 1, :b -> 2}
print(length(map-keys(m)))
print(m[:a])
print(map-has?(m, :b))
print(map-has?(m, :zz))
let m2 = map-remove(m, :a)
print(map-has?(m2, :a))
print(m2[:b])

# ---- list additions ----
print(append(list(1, 2), list(3, 4)))
print(reverse(list(1, 2, 3)))
print(nth(1, list(10, 20, 30)))
print(drop(2, list(1, 2, 3, 4)))
print(member?(3, list(1, 2, 3)))
print(member?(9, list(1, 2, 3)))
print(each!(fn(x) { print(x) }, list(7, 8)))

# ---- assert: passing form returns nil ----
print(if 1 = 1 { nil } else { error("assertion failed: (= 1 1) at tests/028-stdlib.pp:51") })
print(if true { nil } else {
  error(string-append("custom", " at tests/028-stdlib.pp:52"))
})
