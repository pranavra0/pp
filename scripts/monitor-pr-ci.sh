#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'usage: %s [--repo OWNER/REPO] [--interval SECONDS] [--timeout SECONDS] [--failure-dir DIR] PR\n' "$0" >&2
}

repo="pranavra0/pp"
interval=30
timeout=0
failure_dir=".ci-failures"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      repo=$2
      shift 2
      ;;
    --interval)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      interval=$2
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      timeout=$2
      shift 2
      ;;
    --failure-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      failure_dir=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

[ "$#" -eq 1 ] || { usage; exit 2; }
pr=$1

case "$interval" in
  ''|*[!0-9]*) printf 'interval must be a non-negative integer\n' >&2; exit 2 ;;
esac
case "$timeout" in
  ''|*[!0-9]*) printf 'timeout must be a non-negative integer\n' >&2; exit 2 ;;
esac
command -v gh >/dev/null || { printf 'monitor-pr-ci: gh is required\n' >&2; exit 127; }
command -v jq >/dev/null || { printf 'monitor-pr-ci: jq is required\n' >&2; exit 127; }

started=$(date +%s)
mkdir -p "$failure_dir"

while :; do
  error_file=$(mktemp)
  trap 'rm -f "$error_file"' EXIT
  set +e
  checks=$(gh pr checks "$pr" --repo "$repo" --json name,state,bucket,link,workflow 2>"$error_file")
  gh_status=$?
  set -e

  if ! jq -e . >/dev/null 2>&1 <<<"$checks"; then
    printf 'monitor-pr-ci: unable to read checks for %s#%s\n' "$repo" "$pr" >&2
    cat "$error_file" >&2
    exit "$gh_status"
  fi
  rm -f "$error_file"
  trap - EXIT

  total=$(jq 'length' <<<"$checks")
  failed=$(jq '[.[] | select(.bucket == "fail" or .bucket == "cancel")] | length' <<<"$checks")
  pending=$(jq '[.[] | select(.bucket == "pending")] | length' <<<"$checks")

  if [ "$failed" -gt 0 ]; then
    report="$failure_dir/pr-${pr}-$(date -u +%Y%m%dT%H%M%SZ).log"
    {
      printf 'Pull request %s#%s failed checks\n\n' "$repo" "$pr"
      jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | [.name, .bucket, .link] | @tsv' <<<"$checks"
      printf '\nFailed job logs:\n'
      while IFS=$'\t' read -r name bucket link; do
        printf '\n===== %s [%s] =====\n' "$name" "$bucket"
        if [[ "$link" =~ /runs/([0-9]+)/ ]]; then
          gh run view "${BASH_REMATCH[1]}" --repo "$repo" --log-failed || true
        else
          printf 'job URL: %s\n' "$link"
        fi
      done < <(jq -r '.[] | select(.bucket == "fail" or .bucket == "cancel") | [.name, .bucket, .link] | @tsv' <<<"$checks")
    } | tee "$report" >&2
    printf '\nmonitor-pr-ci: failure report written to %s\n' "$report" >&2
    exit 1
  fi

  if [ "$total" -gt 0 ] && [ "$pending" -eq 0 ]; then
    printf 'CI green for %s#%s (%d checks)\n' "$repo" "$pr" "$total"
    exit 0
  fi

  elapsed=$(( $(date +%s) - started ))
  if [ "$timeout" -gt 0 ] && [ "$elapsed" -ge "$timeout" ]; then
    printf 'monitor-pr-ci: timed out after %ss (%d checks, %d pending)\n' "$elapsed" "$total" "$pending" >&2
    exit 124
  fi

  printf 'CI pending for %s#%s (%d checks, %d pending); polling in %ss\n' \
    "$repo" "$pr" "$total" "$pending" "$interval"
  sleep "$interval"
done
