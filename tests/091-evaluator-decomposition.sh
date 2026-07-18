#!/usr/bin/env bash
# Characterize the evaluator seams together: application, module export/import,
# pattern guards, and dynamic effect handlers must still share one evaluator.
set -uo pipefail
. "$(dirname "$0")/lib.sh"

cat > "$TMP/evaluator.pp" <<'EOF'
def add-one(x) { x + 1 }
let (m = module {
  def twice(x) { x * 2 }
}) {
  import(m)
  print(add-one(twice(20)))
}
print(match [1, 2] { [a, b] if a = 1 => a + b; _ => 0 })
def answer(x) { x + 10 }
print(with-handler(ask = answer) { perform ask(32) })
EOF

expected=$'41\n3\n42'
got=$($PP "$TMP/evaluator.pp" 2>&1)
if [ "$got" = "$expected" ]; then
  ok "evaluator-decomposition-characterization"
else
  bad "evaluator-decomposition-characterization" \
      "expected: $(printf '%q' "$expected")" \
      "got:      $(printf '%q' "$got")"
fi

rm -rf "$TMP"
exit "$fail"
