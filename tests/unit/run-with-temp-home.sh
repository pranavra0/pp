#!/usr/bin/env bash
set -euo pipefail

home=$(mktemp -d)
trap 'rm -rf "$home"' EXIT
export HOME="$home"
exec "$@"
