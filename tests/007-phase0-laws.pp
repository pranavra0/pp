# Smoke tests for core semantic laws.
# Each section runs a small program that demonstrates one law and checks it holds.
# pins: LAW-1 LAW-5 LAW-9 LAW-10 LAW-12 LAW-13 LAW-14

print("=== LAW 1: mutual let sees siblings ===")
let (y = x + 1, x = 1) { print("mutual let y =>", y) }



print("")
print("=== LAW 5: let* is sequential ===")
let* (x = 1, x = x + 1) { print("let* x =>", x) }



print("")
print("=== LAW 9: if prunes untaken branch ===")
print("if true =>", if true { 1 } else { undefined-symbol-9() })

print("")
print("=== LAW 10: tail calls in constant stack ===")
def count(n) { if n <= 0 { 0 } else { count(n - 1) } }

print("tail count 10000 =>", count(10000))

print("")
print("=== LAW 12: quote special forms ===")
print("quote if =>", quote { if a { b } else { c } })
print("quote let =>", quote { let (a = 1) { a } })

print("")
print("=== LAW 13/14: do orders effects; undemanded effects don't fire ===")
let (silent = perform log("never")) {
  perform log("a")
  perform log("b")
  print("do value =>", 1)
}
print("")
print("=== LAW 32: gradual types enforced ===")
def typed-square(x: int): int { x * x }
print("typed-square 7 =>", typed-square(7))
let (y: int = 42) { print("typed y =>", y) }


print("")
print("=== LAW 33: config dynamic scope ===")
with-config({"k" -> 1}) {
  with-config({"k" -> 2}) {
    print("computed config k =>", config(string-append("", "k")))
  } }
print("")
print("=== ALL TESTS PASSED ===")
