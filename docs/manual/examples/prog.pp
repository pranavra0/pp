def expensive() {
  node { print("compiling greeter.o"); 6 * 7 } }
print(expensive())
