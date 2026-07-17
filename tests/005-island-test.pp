# An island resolve is content-addressed and pin-verified; this test checks
# the no-pin error path, which needs no cache state.
# An unpinned island is a hard error naming the fix — identical in both
# surfaces. Full pinned round-trips (update/cache/tamper/offline) live in
# tests/035-islands.sh.
print("=== Island Semantics ===")
island("github:test/example")
print("unreachable: unpinned island must error")
