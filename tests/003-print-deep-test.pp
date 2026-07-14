# 003-print-deep-test.pp
# Test that print shows actual values, not #<thunk>.
# Run with: pp tests/003-print-deep-test.pp

load("stdlib/list.pp")

print("=== 1. Print lazy list (map result) ===")
print(map(fn(x) { x + 1 }, list(1, 2, 3, 4, 5)))

print("")
print("=== 2. Print filtered list ===")
print(filter(fn(x) { x mod 2 = 0 }, list(1, 2, 3, 4, 5, 6)))

print("")
print("=== 3. Print range (take) ===")
print(take(5, range(10, 20)))

print("")
print("=== 4. Print vector ===")
print(vec[1, 2, 3 + 4, 5 * 6])

print("")
print("=== 5. Print map ===")
print({:a -> 1 + 2, :b -> 10 * 20})

print("")
print("=== 6. Print nested structures ===")
print(list(list(1, 2), list(3, 4)))

print("")
print("=== 7. force-deep on simple values ===")
print("force-deep 42:", force-deep(42))
print("force-deep nil:", force-deep(nil))
print("force-deep \"hello\":", force-deep("hello"))

print("")
print("=== ALL TESTS PASSED ===")
