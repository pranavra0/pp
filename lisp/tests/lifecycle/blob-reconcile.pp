let (obj = force(node {
  perform log("LIFECYCLE-BLOB")
  blob("LIFECYCLE-BYTES")
})) {
  {:tree -> {"built.bin" -> {:kind -> :file, :mode -> 420, :blob -> obj}}}
}
