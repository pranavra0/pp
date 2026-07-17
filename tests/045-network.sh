#!/usr/bin/env bash
# `--grant net:<host>[:<port>]` mints CapNetwork {host; port}. `(perform
# http-get url)` / `(perform http-post url body)` fork curl (no new OCaml
# networking/TLS surface) but are AUTHORIZED against CapNetwork
# host[:port] — never CapProcess. Banned inside node bodies (trace_stack
# guard, mirroring `fenced`/`write-file`'s node arm). Result shape:
# `{"status" INT "body" STRING}`.
#
# Gated on curl AND python3 (a tiny stdlib HTTP server, no external
# dependency) both being present; skips cleanly otherwise — no real network
# access, a loopback server on an ephemeral port only.
set -uo pipefail
PP=${PP:-bin/pp}
case "$PP" in /*) : ;; *) PP="$PWD/$PP" ;; esac

if ! command -v curl >/dev/null 2>&1; then
  echo "skip 045-network: curl not found on PATH"
  exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "skip 045-network: python3 not found on PATH"
  exit 0
fi

TMP=$(mktemp -d)
export HOME="$TMP"
fail=0
SERVER_PID=""

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

assert() {  # NAME PATTERN present|absent  [FILE]
  local name="$1" pat="$2" mode="$3" file="${4:-$TMP/out}"
  local got
  if grep -qE "$pat" "$file"; then got=present; else got=absent; fi
  if [ "$got" = "$mode" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name: expected '$pat' $mode in $file, got $got"
    echo "--- output ---"; cat "$file"; fail=1
  fi
}

# ---- a tiny loopback HTTP server: GET returns a marker, POST echoes body ----
cat > "$TMP/server.py" <<'PYEOF'
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"GET-MARKER-abc123\n")
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        self.send_response(201)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(b"POST-ECHO:" + body)
    def log_message(self, *args):
        pass

HTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
PYEOF

PORT=$(( (RANDOM % 5000) + 20000 ))
python3 "$TMP/server.py" "$PORT" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the server to come up (bounded poll — no fixed sleep race).
up=0
for _ in $(seq 1 50); do
  if curl -sS -o /dev/null "http://127.0.0.1:$PORT/" 2>/dev/null; then up=1; break; fi
  sleep 0.1
done
if [ "$up" -ne 1 ]; then
  echo "skip 045-network: local test server never came up"
  exit 0
fi

URL="http://127.0.0.1:$PORT/"

# (1) no net grant → Capability_error, no request made.
# =====================================================================
cat > "$TMP/get.pp" <<EOF
print(perform http-get("$URL"))
EOF
"$PP" "$TMP/get.pp" > "$TMP/out" 2>&1
assert "no-capability-error" "capability error" present
assert "no-capability-no-curl" "GET-MARKER-abc123" absent
# =====================================================================
# (2) wrong-host grant → denied (component-aware, not a substring match).
"$PP" --grant "net:127.0.0.2:$PORT" "$TMP/get.pp" > "$TMP/out" 2>&1
assert "wrong-host-no-curl" "GET-MARKER-abc123" absent
assert "wrong-host-denied" "capability error" present

# (3) right grant → http-get succeeds against the local server.
"$PP" --grant "net:127.0.0.1:$PORT" "$TMP/get.pp" > "$TMP/out" 2>&1
assert "right-grant-marker" "GET-MARKER-abc123" present
assert "right-grant-status" '"status" 200' present

# A host-wildcard grant (no port) also works.
"$PP" --grant "net:*" "$TMP/get.pp" > "$TMP/out" 2>&1
assert "wildcard-grant-marker" "GET-MARKER-abc123" present

# (4) http-post: right grant, body actually reaches the server (echoed
#     back), status 201.
cat > "$TMP/post.pp" <<EOF
print(perform http-post("$URL", "hello-from-pp"))
EOF
"$PP" --grant "net:127.0.0.1:$PORT" "$TMP/post.pp" > "$TMP/out" 2>&1
assert "post-echoes-body" "hello-from-pp" present
assert "post-status-201"  '"status" 201' present

# (5) http-get inside a node body is an error — fenced effects are barred
#     from node bodies (SPEC law 31).
# =====================================================================
cat > "$TMP/in-node.pp" <<EOF
force(node { perform http-get("$URL") })
EOF
"$PP" --grant "net:127.0.0.1:$PORT" "$TMP/in-node.pp" > "$TMP/out" 2>&1
assert "in-node-body-denied" "may not appear inside node bodies" present

# =====================================================================
# (6) curl absent = clean error (simulated via an empty PATH so `curl`
#     cannot resolve, without needing to actually uninstall it).
# =====================================================================
env -i HOME="$TMP" PATH="$TMP/empty-path" "$PP" --grant "net:127.0.0.1:$PORT" "$TMP/get.pp" > "$TMP/out" 2>&1
assert "curl-absent-clean-error" "curl not found" present

if [ "$fail" -eq 0 ]; then echo "=== NETWORK (M4) TEST PASSED ==="; fi
exit $fail
