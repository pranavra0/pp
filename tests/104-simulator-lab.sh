#!/usr/bin/env bash
# Pins the deterministic network lab, workload generator, bundle, and loopback controller contract.
set -euo pipefail
source tests/lib.sh

if ! command -v deno >/dev/null; then
  echo "SKIP: deno is not installed"
  exit 0
fi

cd simulator
deno task lab validate fixtures/network.ppsim > "$TMP/scenario.json"
grep -q '"version": 1' "$TMP/scenario.json"

deno task workload 8 2 19 > "$TMP/first.ppsim"
deno task workload 8 2 19 > "$TMP/second.ppsim"
cmp "$TMP/first.ppsim" "$TMP/second.ppsim"
deno task lab validate "$TMP/first.ppsim" >/dev/null

PP="$PP" deno task lab bundle fixtures/network.ppsim "$TMP/run.bundle.json"
grep -q '"bundle_version": 1' "$TMP/run.bundle.json"
grep -q '"passed": true' "$TMP/run.bundle.json"

PP="$PP" deno run --allow-net=127.0.0.1 --allow-read --allow-run --allow-write --allow-env controller.ts .. 0 > "$TMP/controller.out" 2> "$TMP/controller.err" &
controller_pid=$!
trap 'kill "$controller_pid" 2>/dev/null || true' EXIT
for _ in $(seq 1 100); do
  [ -s "$TMP/controller.out" ] && break
  sleep 0.05
done
node - "$TMP/controller.out" <<'NODE'
const fs = require("fs");
const line = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").at(-1);
const started = JSON.parse(line);
if (!started.url.startsWith("http://127.0.0.1:") || !started.url.includes("#token=")) process.exit(1);
(async () => {
  const url = new URL(started.url), token = url.hash.slice("#token=".length);
  const bootstrap = await fetch(`${url.origin}/bootstrap`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token }) });
  if (!bootstrap.ok) process.exit(1);
  const session = (await bootstrap.json()).session;
  const scenario = fs.readFileSync("fixtures/network.ppsim", "utf8").replace("../examples/nodes.pp", "examples/nodes.pp");
  const headers = { authorization: `Bearer ${session}`, "x-request-id": "smoke" };
  let run = await fetch(`${url.origin}/run`, { method: "POST", headers, body: scenario });
  let result = await run.json();
  if (!result.approval_required) process.exit(1);
  run = await fetch(`${url.origin}/run`, { method: "POST", headers: { ...headers, "x-grant-approval": result.approval_token }, body: scenario });
  result = await run.json(); if (!result.accepted || !result.running) process.exit(1);
  let recording;
  do {
    await new Promise((resolve) => setTimeout(resolve, 25));
    recording = await fetch(`${url.origin}/recording`, { headers: { authorization: `Bearer ${session}` } });
  } while (recording.status === 202);
  if (!recording.ok) process.exit(1);
  const bundle = await fetch(`${url.origin}/bundle`, { headers: { authorization: `Bearer ${session}` } }).then((response) => response.json());
  if (bundle.bundle_version !== 1 || bundle.network_events.length === 0) process.exit(1);
})().catch((error) => { console.error(error); process.exit(1); });
NODE
