# Regression: a lexical binding that merely shares its name with a type
# annotation must not become a node dependency. The annotation sits in a
# dead branch so the checker never enforces it; the old free-variable rule
# (which walked expr-typed-type) made `cap` a node free variable holding a
# capability and tripped the node authority boundary.
let cap = cap-none()
node f(x) {
  if false {
    let (y: cap = x) { y }
  } else {
    x * 2
  }
}
print(f(21))
print("ok")
