# Island semantics (D2): differential probes that need no cache state.
# An unpinned island is a hard error naming the fix — identical in both
# backends. Full pinned round-trips (update/cache/tamper/offline) live in
# tests/035-islands.sh.
print("=== Island Semantics ===")
island("github:test/example")
print("unreachable: unpinned island must error")
