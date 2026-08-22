#!/usr/bin/env bash
set -uo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
FIXTURE="$ROOT/lisp/tests/store/crash/build.pp"
LISP=""
TIMEOUT_SECONDS=30
MAX_WRITES=256
fail=0

usage() {
  cat >&2 <<'EOF'
usage: scripts/check-lisp-crash.sh --lisp PATH [--timeout-seconds N] [--max-writes N]

PATH is required.  The selected executable must honor PP_CRASH_AT=BOUNDARY:N
for before, mid, pre-rename, and post-rename durable-write hooks.
EOF
}

bad() {
  printf 'FAIL: %s\n' "$*" >&2
  fail=1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lisp)
      [ "$#" -ge 2 ] || { echo 'crash: --lisp requires a path' >&2; exit 2; }
      LISP=$2
      shift 2
      ;;
    --timeout-seconds)
      [ "$#" -ge 2 ] || { echo 'crash: --timeout-seconds requires a value' >&2; exit 2; }
      TIMEOUT_SECONDS=$2
      shift 2
      ;;
    --max-writes)
      [ "$#" -ge 2 ] || { echo 'crash: --max-writes requires a value' >&2; exit 2; }
      MAX_WRITES=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'crash: unrecognized argument: %s\n' "$1" >&2
      usage
      exit 2
      ;;
  esac
done

[ -n "$LISP" ] || { usage; exit 2; }
case "$LISP" in
  /*) ;;
  *) LISP="$(CDPATH= cd -- "$(dirname -- "$LISP")" && pwd -P)/$(basename -- "$LISP")" ;;
esac
[ -x "$LISP" ] || { printf 'crash: Lisp executable is not executable: %s\n' "$LISP" >&2; exit 2; }
[ -f "$FIXTURE" ] || { printf 'crash: fixture is missing: %s\n' "$FIXTURE" >&2; exit 2; }
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*) echo 'crash: timeout must be an integer' >&2; exit 2;; esac
case "$MAX_WRITES" in ''|*[!0-9]*) echo 'crash: max-writes must be an integer' >&2; exit 2;; esac
[ "$TIMEOUT_SECONDS" -gt 0 ] || { echo 'crash: timeout must be positive' >&2; exit 2; }
[ "$MAX_WRITES" -gt 0 ] || { echo 'crash: max-writes must be positive' >&2; exit 2; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/pp-lisp-crash.XXXXXX")
trap 'rm -rf "$TMP"' EXIT HUP INT TERM

invoke() {
  local home=$1 hook=$2 output=$3 error=$4
  set +e
  python3 - "$ROOT" "$LISP" "$FIXTURE" "$home" "$hook" "$output" "$error" \
    "$TIMEOUT_SECONDS" <<'PY'
import os
import subprocess
import sys

root, executable, fixture, home, hook, output, error, timeout = sys.argv[1:]
env = os.environ.copy()
for name in ("PP_DAEMON", "PP_SERVER", "PP_SOCKET"):
    env.pop(name, None)
env["HOME"] = home
if hook:
    env["PP_CRASH_AT"] = hook
else:
    env.pop("PP_CRASH_AT", None)
with open(output, "wb") as out, open(error, "wb") as err:
    process = subprocess.Popen(
        [
            executable,
            "--grant",
            f"fs:{root}/lisp/tests/store/crash:ro",
            fixture,
        ],
        cwd=root,
        env=env,
        stdout=out,
        stderr=err,
    )
    try:
        status = process.wait(timeout=float(timeout))
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise SystemExit(124)
raise SystemExit(128 - status if status < 0 else status)
PY
  local status=$?
  set -uo pipefail
  return "$status"
}

snapshot_store() {
  python3 - "$1" "$2" <<'PY'
from hashlib import sha256
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
out = Path(sys.argv[2])
if root.is_symlink() or not root.is_dir():
    raise SystemExit(f"store root is not a directory: {root}")
hex64 = re.compile(r"[0-9a-f]{64}\Z")
hashed = {"objects", "traces", "blobs", "fenced-specs"}
areas = hashed | {"procs", "locks"}
rows = []
blob_seen = False
object_seen = False
trace_seen = False
for path in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
    rel = path.relative_to(root)
    if path.is_symlink():
        raise SystemExit(f"store symlink: {rel}")
    if path.is_dir():
        if any(part.startswith(".") for part in rel.parts) or ".tmp" in path.name:
            raise SystemExit(f"store temporary/hidden directory: {rel}")
        if rel.parts[0] not in areas:
            raise SystemExit(f"noncanonical store directory: {rel}")
        continue
    if not path.is_file():
        raise SystemExit(f"store non-file: {rel}")
    if any(part.startswith(".") for part in rel.parts):
        raise SystemExit(f"store temporary/hidden file: {rel}")
    if ".tmp" in path.name or ".pp-tmp." in path.name:
        raise SystemExit(f"store temporary file: {rel}")
    if rel.parts[0] == "locks":
        continue
    data = path.read_bytes()
    if rel == Path("gc-roots"):
        if not data:
            raise SystemExit("gc-roots is empty")
        if b"\r" in data or not data.endswith(b"\n") or any(
            not line for line in data.splitlines()
        ):
            raise SystemExit("noncanonical gc-roots")
    if rel == Path("VERSION") and data != b"pp-store 2\n":
        raise SystemExit("noncanonical VERSION")
    if rel.parts[0] == "blobs":
        blob_seen = True
    if rel.parts[0] == "objects":
        object_seen = True
    if rel.parts[0] == "traces":
        trace_seen = True
    if rel.parts[0] in hashed and len(rel.parts) != 2:
        raise SystemExit(f"noncanonical store path: {rel}")
    if len(rel.parts) == 2 and rel.parts[0] in hashed and not hex64.fullmatch(rel.name):
        raise SystemExit(f"noncanonical store name: {rel}")
    if rel.parts[0] == "traces":
        if (b"\r" in data or not data.endswith(b"\n") or any(
            not line or not line.startswith(b"(trace ") or not line.endswith(b")")
            for line in data.splitlines()
        )):
            raise SystemExit(f"noncanonical trace record: {rel}")
    rows.append(f"{rel.as_posix()}\t{len(data)}\t{sha256(data).hexdigest()}\n")
required = {
    "VERSION": root / "VERSION",
    "objects": root / "objects",
    "traces": root / "traces",
}
for name, path in required.items():
    if path.is_symlink() or not (path.is_file() if name == "VERSION" else path.is_dir()):
        raise SystemExit(f"store {name} is missing")
if not object_seen:
    raise SystemExit("store object fixture is missing")
if not trace_seen:
    raise SystemExit("store trace fixture is missing")
if not blob_seen:
    raise SystemExit("store blob fixture is missing")
out.write_text("".join(rows), encoding="ascii")
PY
}

compare_store() {
  python3 - "$1" "$2" <<'PY'
from pathlib import Path
import sys

def files(root):
    result = {}
    for path in root.rglob("*"):
        rel = path.relative_to(root)
        if path.is_symlink():
            raise SystemExit(f"store symlink: {rel}")
        if path.is_file() and rel.parts[0] != "locks":
            result[rel.as_posix()] = path.read_bytes()
    return result

left = files(Path(sys.argv[1]))
right = files(Path(sys.argv[2]))
if set(left) != set(right):
    missing = sorted(set(left) - set(right))
    extra = sorted(set(right) - set(left))
    raise SystemExit(f"store inventory differs (missing={missing}, extra={extra})")
for name in sorted(left):
    if left[name] != right[name]:
        raise SystemExit(f"store bytes differ: {name}")
PY
}

check_recovery() {
  local home=$1 label=$2
  local output="$TMP/$label.restart.out" error="$TMP/$label.restart.err"
  local inventory="$TMP/$label.restart.inventory"
  local warm_output="$TMP/$label.warm.out" warm_error="$TMP/$label.warm.err"
  local warm_inventory="$TMP/$label.warm.inventory" status

  invoke "$home" "" "$output" "$error"
  status=$?
  if [ "$status" -ne 0 ]; then
    bad "$label restart status $status"
    return 1
  fi
  if ! cmp -s "$TMP/baseline.out" "$output"; then
    bad "$label restart stdout differs"
    return 1
  fi
  if ! cmp -s "$TMP/baseline.err" "$error"; then
    bad "$label restart stderr differs"
    return 1
  fi
  if ! snapshot_store "$home/.pp/store" "$inventory"; then
    bad "$label restart store is torn or noncanonical"
    return 1
  fi
  if ! cmp -s "$TMP/baseline.inventory" "$inventory"; then
    bad "$label restart inventory differs"
    return 1
  fi
  if ! compare_store "$TMP/baseline-home/.pp/store" "$home/.pp/store"; then
    bad "$label restart store bytes differ"
    return 1
  fi

  invoke "$home" "" "$warm_output" "$warm_error"
  status=$?
  if [ "$status" -ne 0 ]; then
    bad "$label warm status $status"
    return 1
  fi
  if ! cmp -s "$TMP/baseline.out" "$warm_output" || \
     ! cmp -s "$TMP/baseline.err" "$warm_error"; then
    bad "$label warm output differs"
    return 1
  fi
  if ! snapshot_store "$home/.pp/store" "$warm_inventory" || \
     ! cmp -s "$TMP/baseline.inventory" "$warm_inventory" || \
     ! compare_store "$TMP/baseline-home/.pp/store" "$home/.pp/store"; then
    bad "$label warm store differs or is noncanonical"
    return 1
  fi
  return 0
}

baseline_home="$TMP/baseline-home"
mkdir -p "$baseline_home"
invoke "$baseline_home" "" "$TMP/baseline.out" "$TMP/baseline.err"
baseline_status=$?
if [ "$baseline_status" -ne 0 ]; then
  bad "clean build status $baseline_status"
  exit "$fail"
fi
if [ ! -s "$TMP/baseline.out" ]; then
  bad "clean build produced no stdout"
  exit "$fail"
fi
if ! snapshot_store "$baseline_home/.pp/store" "$TMP/baseline.inventory"; then
  bad "clean build store is torn or noncanonical"
  exit "$fail"
fi
printf 'baseline status=0 files=%s\n' "$(wc -l <"$TMP/baseline.inventory")"

crashes=0
recovered=0
for boundary in before mid pre-rename post-rename; do
  seen=0
  finished=0
  for n in $(seq 1 "$MAX_WRITES"); do
    home="$TMP/$boundary-$n/home"
    mkdir -p "$home"
    output="$TMP/$boundary-$n.crash.out"
    error="$TMP/$boundary-$n.crash.err"
    invoke "$home" "$boundary:$n" "$output" "$error"
    status=$?
    if [ "$status" -eq 137 ]; then
      seen=1
      crashes=$((crashes + 1))
      if check_recovery "$home" "$boundary-$n"; then
        recovered=$((recovered + 1))
      fi
      continue
    fi
    if [ "$status" -eq 0 ]; then
      [ "$seen" -eq 1 ] || bad "$boundary hook did not kill a write"
      finished=1
      break
    fi
    bad "$boundary:$n returned unexpected status $status"
    finished=1
    break
  done
  [ "$finished" -eq 1 ] || bad "$boundary exceeded --max-writes"
done

[ "$crashes" -gt 0 ] || bad "no SIGKILL crash points observed"
[ "$crashes" -eq "$recovered" ] || bad "$recovered/$crashes crash points recovered"
if [ "$fail" -eq 0 ]; then
  printf 'LISP CRASH-INJECTION PASSED crashes=%s boundaries=4\n' "$crashes"
fi
exit "$fail"
