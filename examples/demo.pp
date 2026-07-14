# pp demo: let*, fexprs, and capabilities working together
# Run with: pp examples/demo.pp

print("=== 1. let* (sequential let) ===")
let* (x = 10, y = x + 20, z = y * 2) { print("x =", x, ", y =", y, ", z =", z) }




print("")
print("=== 2. fexprs — if as a library, not a special form ===")

# my-if is an operative (fexpr): it receives unevaluated arguments
# and decides which ones to force
def-fexpr(my-if(cond, then, (else)), if force(cond) { force(then) } else {
  force((else))
})


# Use it — behaves exactly like built-in if
print("my-if true  →", my-if(true, 1, 2))
print("my-if false →", my-if(false, 1, 2))

# my-when: only evaluate body if condition is truthy
def-fexpr(my-when(cond, body), if force(cond) { force(body) })




print("my-when true:", my-when(true, print("  (this printed)")))
print("my-when false:", my-when(false, print("  (this should NOT print)")))

print("")
print("=== 3. Capabilities ===")

# Create capabilities — these are first-class values
let* (ro-cap = filesystem("/etc", :ro), rw-cap = filesystem("/tmp", :rw), net-cap = network(:tcp)) {
  print("read-only cap:", ro-cap)
  print("read-write cap:", rw-cap)
  print("network cap:", net-cap)
  let (all-caps = cap-compose(ro-cap, net-cap)) { print("composed:", all-caps) }
  let (restricted = cap-restrict(rw-cap, "myapp")) {
    print("restricted:", restricted)
  }
# Compose multiple capabilities
}


# Restrict a capability to a subdirectory



print("")
print("=== 4. Effect block with capabilities ===")

# An effectful function that declares needed capabilities
def read-config(path) {
  effect(:capabilities, [filesystem(path, :ro)], print("would read config from", path), string-append("config for ", path))
}
# perform read-file(path)


print(read-config("/etc/app/config.toml"))

print("")
print("=== Done ===")
print("let* works, fexprs work, capabilities are first-class values")
