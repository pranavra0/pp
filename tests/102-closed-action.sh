#!/usr/bin/env bash
# `run-closed!` accepts only immutable tool/input trees, rejects path escape
# before execution, and either enters a network/filesystem namespace or fails
# explicitly when the host cannot provide that namespace.
# pins: LAW-16 LAW-18 LAW-22
set -uo pipefail
. "$(dirname "$0")/lib.sh"

run() { "$PP" "$@" >"$TMP/out" 2>&1; }

cat >"$TMP/no-cap.pp" <<'EOF'
let result = run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob("not-a-tool")}}},
  :tool-path -> "tool",
  :args -> [],
  :inputs -> {:tree -> {}},
  :env -> {},
  :platform -> {"os" -> "linux"},
  :outputs -> []
})
EOF
run "$TMP/no-cap.pp"
if grep -q "no process authority" "$TMP/out"; then ok "closed-no-cap"
else bad "closed-no-cap" "$(cat "$TMP/out")"; fi

cat >"$TMP/traversal.pp" <<'EOF'
run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob("not-a-tool")}}},
  :tool-path -> "tool",
  :args -> [],
  :inputs -> {:tree -> {"../escape" -> {:kind -> :file, :mode -> 420, :blob -> blob("input")}}},
  :env -> {},
  :platform -> {"os" -> "linux"},
  :outputs -> []
})
EOF
run --grant process "$TMP/traversal.pp"
if grep -q "non-canonical tree path" "$TMP/out"; then ok "closed-input-traversal"
else bad "closed-input-traversal" "$(cat "$TMP/out")"; fi

cat >"$TMP/output-traversal.pp" <<'EOF'
run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob("not-a-tool")}}},
  :tool-path -> "tool",
  :args -> [],
  :inputs -> {:tree -> {}},
  :env -> {},
  :platform -> {"os" -> "linux"},
  :outputs -> ["../escape"]
})
EOF
run --grant process "$TMP/output-traversal.pp"
if grep -q "rejects non-canonical output path" "$TMP/out"; then ok "closed-output-traversal"
else bad "closed-output-traversal" "$(cat "$TMP/out")"; fi

cat >"$TMP/platform.pp" <<'EOF'
run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob("not-a-tool")}}},
  :tool-path -> "tool",
  :args -> [],
  :inputs -> {:tree -> {}},
  :env -> {},
  :platform -> {"os" -> "plan9"},
  :outputs -> []
})
EOF
run --grant process "$TMP/platform.pp"
if grep -q "requires :platform" "$TMP/out"; then ok "closed-platform-denied"
else bad "closed-platform-denied" "$(cat "$TMP/out")"; fi

cat >"$TMP/environment.pp" <<'EOF'
run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob("not-a-tool")}}},
  :tool-path -> "tool",
  :args -> [],
  :inputs -> {:tree -> {}},
  :env -> {"BAD=NAME" -> "value"},
  :platform -> {"os" -> "linux"},
  :outputs -> []
})
EOF
run --grant process "$TMP/environment.pp"
if grep -q "invalid environment name" "$TMP/out"; then ok "closed-environment-denied"
else bad "closed-environment-denied" "$(cat "$TMP/out")"; fi

cat >"$TMP/policy.pp" <<'EOF'
run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob("not-a-tool")}}},
  :tool-path -> "tool",
  :args -> [],
  :inputs -> {:tree -> {}},
  :env -> {},
  :platform -> {"os" -> "linux"},
  :policy -> fn() { nil },
  :outputs -> []
})
EOF
run --grant process "$TMP/policy.pp"
if grep -q "expects :policy to be canonical data" "$TMP/out"; then
  ok "closed-policy-canonical"
else
  bad "closed-policy-canonical" "$(cat "$TMP/out")"
fi

cat >"$TMP/node.pp" <<'EOF'
force(node {
  run-closed!({
    :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob("not-a-tool")}}},
    :tool-path -> "tool",
    :args -> [],
    :inputs -> {:tree -> {}},
    :env -> {},
    :platform -> {"os" -> "linux"},
    :outputs -> []
  })
})
EOF
run --grant process "$TMP/node.pp"
if grep -q "executor classifies this request as scripting-only" "$TMP/out"; then
  ok "closed-node-denied"
else
  bad "closed-node-denied" "$(cat "$TMP/out")"
fi

tool=
for candidate in /usr/bin/cosign-linux-amd64 /usr/bin/init.lxc.static; do
  if [ -x "$candidate" ]; then tool="$candidate"; break; fi
done

if [ -n "$tool" ]; then
  cat >"$TMP/execute.pp" <<EOF
let result = run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob(\$file("$tool"))}}},
  :tool-path -> "tool",
  :args -> ["--help"],
  :inputs -> {:tree -> {}},
  :env -> {"EXPLICIT" -> "yes"},
  :platform -> {"os" -> "linux"},
  :outputs -> []
})
print(hash-map-get(result, :exit))
EOF
  run --grant process --grant "fs:$tool:ro" "$TMP/execute.pp"
  if grep -q "closed Linux runner unavailable" "$TMP/out"; then
    ok "closed-host-fails-closed"
  elif grep -qE '^[0-9]+$' "$TMP/out"; then
    ok "closed-static-tool-executes"
  else
    bad "closed-static-tool-executes" "$(cat "$TMP/out")"
  fi
else
  ok "closed-static-tool-unavailable"
fi

if command -v go >/dev/null 2>&1; then
  CGO_ENABLED=0 go build -o "$TMP/hostile" \
    "$(dirname "$0")/fixtures/closed-hostile.go"

  cat >"$TMP/hostile.pp" <<EOF
let result = run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob(\$file("$TMP/hostile"))}}},
  :tool-path -> "tool",
  :args -> ["report"],
  :inputs -> {:tree -> {"input" -> {:kind -> :file, :mode -> 292, :blob -> blob("input")}}},
  :env -> {"EXPLICIT" -> "yes"},
  :platform -> {"os" -> "linux"},
  :outputs -> ["result"]
})
let evidence = hash-map-get(result, :evidence)
let resources = hash-map-get(result, :resources)
print(hash-map-get(result, :stdout))
print(hash-map-get(evidence, "clock"))
print(hash-map-get(evidence, "randomness"))
print(hash-map-get(resources, "limits"))
EOF
  run --grant process --grant "fs:$TMP/hostile:ro" "$TMP/hostile.pp"
  if grep -q "closed Linux runner unavailable" "$TMP/out"; then
    ok "closed-hostile-runner-unavailable"
  else
    for fact in filesystem-denied=true environment-cleared=true \
        environment-explicit=yes network-denied=true child-ok \
        subprocess-confined=true loader-denied=true randomness-available=true \
        clock-available=true; do
      if grep -q "$fact" "$TMP/out"; then ok "closed-hostile-$fact"
      else bad "closed-hostile-$fact" "$(cat "$TMP/out")"; fi
    done
    if [ "$(grep -c '^"ambient"$' "$TMP/out")" -eq 3 ]; then
      ok "closed-ambient-evidenced"
    else
      bad "closed-ambient-evidenced" "$(cat "$TMP/out")"
    fi

    ORIGIN="$TMP/origin"
    DESTINATION="$TMP/destination"
    SHARED="$TMP/shared"
    mkdir -p "$ORIGIN" "$DESTINATION"
    TOOL_HASH=$(sha256sum "$TMP/hostile" | cut -d' ' -f1)
    INPUT_HASH=$(printf portable-tree-input | sha256sum | cut -d' ' -f1)
    cat >"$TMP/ingest.pp" <<EOF
blob(\$file("$TMP/hostile"))
blob("portable-tree-input")
EOF
    HOME="$ORIGIN" "$PP" --grant "fs:$TMP/hostile:ro" "$TMP/ingest.pp" >/dev/null
    HOME="$ORIGIN" "$PP" --transport-push blob "$TOOL_HASH" "$SHARED" >/dev/null
    HOME="$ORIGIN" "$PP" --transport-push blob "$INPUT_HASH" "$SHARED" >/dev/null
    HOME="$DESTINATION" "$PP" --transport-pull blob "$TOOL_HASH" "$SHARED" >/dev/null
    HOME="$DESTINATION" "$PP" --transport-pull blob "$INPUT_HASH" "$SHARED" >/dev/null
    cat >"$TMP/portable.pp" <<EOF
let result = run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> "$TOOL_HASH"}}},
  :tool-path -> "tool",
  :args -> ["copy"],
  :inputs -> {:tree -> {"input" -> {:kind -> :file, :mode -> 292, :blob -> "$INPUT_HASH"}}},
  :env -> {},
  :platform -> {"os" -> "linux"},
  :outputs -> ["result"]
})
let tree = result[:outputs][:tree]
print(blob-get(tree["result"][:blob]))
print(tree)
EOF
    HOME="$DESTINATION" run --grant process "$TMP/portable.pp"
    if grep -q '^"portable-tree-input"$' "$TMP/out" \
        && grep -q ':mode 416' "$TMP/out"; then
      ok "closed-tree-empty-store-portable"
    else
      bad "closed-tree-empty-store-portable" "$(cat "$TMP/out")"
    fi

    cat >"$TMP/escape.pp" <<EOF
let result = run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob(\$file("$TMP/hostile"))}}},
  :tool-path -> "tool",
  :args -> ["escape"],
  :inputs -> {:tree -> {"input" -> {:kind -> :file, :mode -> 292, :blob -> blob("input")}}},
  :env -> {},
  :platform -> {"os" -> "linux"},
  :outputs -> ["escape"]
})
print(hash-map-get(result, :outputs))
EOF
    run --grant process --grant "fs:$TMP/hostile:ro" "$TMP/escape.pp"
    if grep -q ':kind :symlink' "$TMP/out"; then
      ok "closed-output-symlink-preserved"
    else
      bad "closed-output-symlink-escape" "$(cat "$TMP/out")"
    fi

    cat >"$TMP/signal.pp" <<EOF
let result = run-closed!({
  :tool -> {:tree -> {"tool" -> {:kind -> :file, :mode -> 493, :blob -> blob(\$file("$TMP/hostile"))}}},
  :tool-path -> "tool",
  :args -> ["signal"],
  :inputs -> {:tree -> {}},
  :env -> {},
  :platform -> {"os" -> "linux"},
  :outputs -> []
})
print(hash-map-get(result, :exit))
print(hash-map-get(hash-map-get(result, :evidence), "signals"))
EOF
    run --grant process --grant "fs:$TMP/hostile:ro" "$TMP/signal.pp"
    if grep -q '^143$' "$TMP/out" && grep -q '^"exit-status"$' "$TMP/out"; then
      ok "closed-signal-evidenced"
    else
      bad "closed-signal-evidenced" "$(cat "$TMP/out")"
    fi
  fi
else
  ok "closed-hostile-helper-unavailable"
fi

rm -rf "$TMP"
exit "$fail"
