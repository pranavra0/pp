# pp example: lazy evaluation demo
# Demonstrates: let, delay, force, thunks

# Create an expensive computation (this won't run yet)
let (x = delay(do {
  print("this expensive computation runs NOW")
  100 * 200
}), y = delay(print("THIS SHOULD NEVER PRINT"))) {
# This one is defined but never used — so it never runs
  print("Before forcing x")
  print(force(x))
  print("After forcing x")
  print("Done — y was never forced")
}



# y is never forced, so the error never fires
