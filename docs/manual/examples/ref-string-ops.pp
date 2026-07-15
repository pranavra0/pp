# String builtins: append, length, split, substring, index-of, trim, and
# number conversion. f-strings (`f"..."`) provide interpolation.
print(string-append("foo", "bar"))
print(string-length("hello"))
print(string-split("a,b,c", ","))
print(string-sub("hello", 1, 3))
print(string-index("hello", "ll"))
print(string-trim("  hi  "))
print(number->string(42))
print(string->number("3.14"))
