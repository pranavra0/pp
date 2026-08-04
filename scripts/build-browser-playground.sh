#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
dune build src/browser/browser_main.js
rm -f web/pp-browser.js
cp _build/default/src/browser/browser_main.js web/pp-browser.js
printf '%s\n' "browser playground runtime written to web/pp-browser.js"
