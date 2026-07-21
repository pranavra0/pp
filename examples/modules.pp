# A module evaluates in a fresh scope and exports its definitions for import.
let geometry = module {
  let pi = 3.14159
  def area(radius) { pi * (radius * radius) }
}

import(geometry)
print(area(10))
