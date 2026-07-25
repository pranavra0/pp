# Adversarial desired state whose root contains a volatile probe value.
load("stdlib/list.pp")
load("stdlib/string.pp")

let (metrics-file = nth(0, argv()), sentinel-file = nth(1, argv())) {
  register-probe("replica-count",
    fn() {
      perform write-file(sentinel-file, "observe-fn ran\n")
      string->number(string-trim(slurp(metrics-file)))
    },
    cap-compose(
      cap-restrict(current-capabilities(), metrics-file, :ro),
      cap-restrict(current-capabilities(), sentinel-file, :wo)))
  {"replicas" -> probe("replica-count")}
}
