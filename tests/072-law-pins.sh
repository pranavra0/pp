#!/usr/bin/env bash
# tests/072 — every SPEC law claimed to hold must have a real test backing it.
#
# SPEC.md gives every law an explicit **Status** marker; a law marked "holds"
# is a claim that the engine satisfies it. This script is the mechanism that
# stops such a claim from being unbacked: it cross-references every LAW id in
# SPEC against the `# pins: LAW-<n>` markers declared in the test suite and
# fails the build when a "holds" law has neither a pinned test nor an explicit
# entry on the PENDING backfill list.
#
# The ratchet (obligations attached to a gate, never a checklist):
#   * a NEW law added to SPEC as "holds" with no pin and no PENDING entry is a
#     red build — laws can be added, never quietly;
#   * a pin that names a nonexistent LAW id (a typo, or a law that was renamed
#     or deleted) is a red build — pins cannot rot;
#   * the PENDING list is self-cleaning: an entry that is actually pinned (so it
#     should be promoted) or that no longer names a "holds" law is a red build.
#
# Every law currently marked "holds" must have a real pinned test. This gate
# is a project invariant: a new law must arrive with behavioral evidence, not
# a deferred promise.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
ROOT="${DUNE_SOURCEROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
SPEC="$ROOT/docs/SPEC.md"
TESTS="$ROOT/tests"

# All current "holds" laws are pinned. Keep this empty rather than weakening
# the gate with an unreviewed backlog.
PENDING=""

# ---- 1. Parse SPEC: emit "<law-id> <status-word>" for every law. -----------
# BSD/awk-portable: no gawk match() arrays. Take the first **Status:** line
# after each `### [LAW <id>]` header as that law's status.
law_status=$(awk '
  /^### \[LAW /{
    s=$0; sub(/^### \[LAW /,"",s); i=index(s,"]"); cur=substr(s,1,i-1);
    have=0; next
  }
  have==0 && cur!="" && /\*\*Status:/{
    t=$0; sub(/.*Status:/,"",t); sub(/^\**/,"",t); sub(/^ +/,"",t);
    sub(/[^a-zA-Z].*/,"",t);
    print cur, tolower(t); have=1
  }
' "$SPEC")

if [ -z "$law_status" ]; then
  bad "spec-parse" "no laws parsed from $SPEC — parser or file broken"
  echo "$fail"; exit 1
fi

all_ids=$(printf '%s\n' "$law_status" | awk '{print $1}')
holds_ids=$(printf '%s\n' "$law_status" | awk '$2=="holds"{print $1}')

# ---- 2. Collect pinned law ids from `# pins:` markers in the suite. --------
pinned=$(grep -rhE '^#[[:space:]]*pins:' "$TESTS" \
           | grep -oE 'LAW-[0-9]+[a-z]?' | sed 's/LAW-//' | sort -u)

has() { printf '%s\n' "$2" | grep -qx "$1"; }

# ---- 3. Every "holds" law must be pinned or explicitly PENDING. ------------
for id in $holds_ids; do
  if has "$id" "$pinned"; then :
  elif printf '%s\n' $PENDING | grep -qx "$id"; then :
  else
    bad "unpinned-holds-law" \
      "LAW $id is marked 'holds' but has no pinned test and is not on PENDING." \
      "Add a '# pins: LAW-$id' marker to a test that exercises it, or add $id to PENDING with a reason."
  fi
done

# ---- 4. Every pin must name a law that actually exists in SPEC. ------------
for id in $pinned; do
  if ! has "$id" "$all_ids"; then
    where=$(grep -rlE "LAW-$id\b" "$TESTS" | sed "s#$ROOT/##" | paste -sd, -)
    bad "dangling-pin" \
      "A test pins LAW-$id, which does not exist in SPEC (typo, rename, or deletion)." \
      "Referenced by: $where"
  fi
done

# ---- 5. PENDING must stay honest: each entry is a "holds" law and unpinned. -
for id in $PENDING; do
  if ! has "$id" "$holds_ids"; then
    bad "stale-pending" \
      "LAW $id is on PENDING but is not (any longer) a 'holds' law — remove it from PENDING."
  fi
  if has "$id" "$pinned"; then
    bad "promotable-pending" \
      "LAW $id is on PENDING but now HAS a pinned test — remove it from PENDING (promote it)."
  fi
done

# ---- report ----------------------------------------------------------------
n_holds=$(printf '%s\n' "$holds_ids" | grep -c .)
n_pinned_holds=0
for id in $holds_ids; do has "$id" "$pinned" && n_pinned_holds=$((n_pinned_holds+1)); done
n_pending=$(printf '%s\n' $PENDING | grep -c .)
n_all=$(printf '%s\n' "$all_ids" | grep -c .)

echo "law-pins: $n_all laws in SPEC | $n_holds marked holds \
| $n_pinned_holds holds-laws pinned, $n_pending on PENDING (tail)"
# Pinned partial/foundational laws (bonus coverage beyond the holds gate):
echo "law-pins: pinned law ids = $(printf '%s ' $pinned)"

if [ $fail -eq 0 ]; then
  echo "=== LAW-LINKAGE (A″3) TEST PASSED ==="
fi
exit $fail
