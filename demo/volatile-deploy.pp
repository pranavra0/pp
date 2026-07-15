# demo/volatile-deploy.pp — a DELIBERATELY adversarial program, separate from
# the devops deploy demo, whose desired-state ROOT folds a genuinely volatile
# probe directly into its return value (demo/deploy.pp deliberately keeps
# probes report-only, so it needs no pinning at all). This is the ONE shape
# that makes the claim "probe cells are pinned inputs" falsifiable: without
# --pin-file, the published hash tracks metrics-file's current content; with
# --pin-file (a `(pin-probe "replica-count" <value>)` line), the probe's
# observe-fn never runs at all — Primitives.probe_value_for consults
# Runtime.probe_values FIRST and returns the pre-seeded value unconditionally,
# so the desired-state hash reflects the PINNED reading, never whatever
# metrics-file says right now.
#
# argv (after `--`): METRICS-FILE SENTINEL-FILE
# METRICS-FILE  — holds a bare integer (replica count); tests/053
# mutates this between runs to prove the probe is
# really volatile when unpinned.
# SENTINEL-FILE — the observe-fn writes this file every time it
# actually RUNS; tests/053 asserts its ABSENCE under
# --pin-file (the pinned probe short-circuits the
# observe-fn entirely — proof the fn was never called).
#
# The registered capability composes read (metrics-file) + write
# (sentinel-file): probe_value_for replaces the ambient capability set
# with EXACTLY this one value for the observe-fn's call extent, so both
# the slurp and the write-file inside it need to be authorized under it.
load("stdlib/list.pp")
load("stdlib/string.pp")

let (metrics-file = nth(0, argv()), sentinel-file = nth(1, argv())) {
  register-probe("replica-count",


fn() {
    perform write-file(sentinel-file, "observe-fn ran\n")
    string->number(string-trim(slurp(metrics-file)))
  }, cap-compose(cap-restrict(current-capabilities(), metrics-file, :ro), cap-restrict(current-capabilities(), sentinel-file, :wo)))
  {"replicas" -> probe("replica-count")}
}
