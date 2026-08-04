#!/usr/bin/env bash
# Browser playground boundary executes checked-in pure examples through the shared evaluator.
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
while [ ! -f "$root/dune-project" ] && [ "$root" != "/" ]; do
  root=$(dirname "$root")
done
cd "$root"
if [ -x "$root/src/browser/browser_cli.exe" ]; then
  build_root="$root"
else
  build_root="$root/_build/default"
fi
native=$("$build_root/src/browser/browser_cli.exe" < examples/nodes.pp)
NATIVE_JSON="$native" node - <<'NODE'
const result = JSON.parse(process.env.NATIVE_JSON);
if (result.status !== "ok") throw new Error(JSON.stringify(result));
if (!result.stdout.some((line) => line.includes("compute once"))) throw new Error("missing captured output");
if (result.value !== "nil") throw new Error(`unexpected final value: ${result.value}`);
NODE

BROWSER_JSON=$(BUILD_ROOT="$build_root" node - <<'NODE'
const fs = require("fs");
const path = require("path");
const root = process.env.BUILD_ROOT;
require(path.join(root, "src/browser/browser_main.js"));
process.stdout.write(global.ppBrowserRun(fs.readFileSync(path.join(root, "examples/effects.pp"), "utf8")));
NODE
)
BROWSER_JSON="$BROWSER_JSON" node - <<'NODE'
const result = JSON.parse(process.env.BROWSER_JSON);
if (result.status !== "ok") throw new Error(JSON.stringify(result));
if (!result.stdout.some((line) => line.includes("answer: 42"))) throw new Error("missing handler output");
NODE
