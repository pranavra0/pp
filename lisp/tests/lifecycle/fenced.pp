do {
  fenced("lifecycle", {:run -> ["/bin/true"]})
  {:tree -> {"fenced.txt" -> {:kind -> :file, :mode -> 420, :blob -> blob("FENCED")}}}
}
