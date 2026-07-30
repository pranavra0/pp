#!/bin/sh
# One graph: source files become cached artifacts, then a desired tree. The
# filesystem domain applies that tree and repairs drift. The transcript keeps
# the high-level events and hides temporary paths.
export HOME=$(mktemp -d)
trap 'rm -rf "$HOME"' EXIT
SRC="$HOME/src"
OUT="$HOME/release"
mkdir -p "$SRC"
printf 'main-v1\n' > "$SRC/main.src"
printf 'util-v1\n' > "$SRC/util.src"

cat > "$HOME/release.pp" <<EOF
def compile(path, name) {
  node {
    print(string-append("compile ", name))
    blob(string-append(\$file(path), "compiled\\n"))
  }
}

let main = compile("$SRC/main.src", "main")
let util = compile("$SRC/util.src", "util")
{:tree -> {
  "bin" -> {:kind -> :directory, :mode -> 493},
  "bin/main.o" -> {:kind -> :file, :mode -> 420, :blob -> main},
  "bin/util.o" -> {:kind -> :file, :mode -> 420, :blob -> util}
}}
EOF

run() {
  "$PP" --grant "fs:$SRC:ro" --grant "fs:$OUT:rw" --reconcile "$OUT" "$HOME/release.pp" 2>&1 \
    | sed -E 's#root=[^ ]*#root=RELEASE#g' \
    | grep -E 'compile |create=|update=|delete=' || true
}

echo '$ pp --reconcile RELEASE release.pp       # cold release: build and deploy'
run
echo "release files: $(find "$OUT" -type f | sort | sed 's#^.*/release/##' | tr '\n' ' ' | sed 's/ $//')"

echo
echo '$ pp --reconcile RELEASE release.pp       # warm release: graph is a hit'
run

echo
echo '# Change only main.src; util.o remains reusable.'
printf 'main-v2\n' > "$SRC/main.src"
echo '$ pp --reconcile RELEASE release.pp       # incremental release'
run

echo
echo '# Delete a deployed artifact; the desired tree restores it without rebuilding.'
rm "$OUT/bin/util.o"
echo '$ pp --reconcile RELEASE release.pp       # drift repair'
run

echo "main artifact: $(cat "$OUT/bin/main.o")"
echo "util artifact: $(cat "$OUT/bin/util.o")"
