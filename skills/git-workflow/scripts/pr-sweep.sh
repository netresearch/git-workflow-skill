#!/usr/bin/env bash
# pr-sweep.sh — drive a list of pull requests to merge, and stop on anything
# it was not told how to handle.
#
# Why this exists: pr-status.sh --watch follows ONE pull request. A sweep over
# twenty or more PRs in many repositories kept being hand-written, and the
# hand-written drivers dispatched on a few actions and sent everything else to
# a default "keep waiting" branch. Two of them sat silent for four hours with
# `NEXT: request-review` on their PRs, because that action fell into the
# default branch. Here the default branch STOPS: only the actions listed below
# are handled, and every other value — including one pr-status.sh adds in a
# later version — ends the sweep with a line in the attention file.
#
# Usage:
#   pr-sweep.sh [--interval SEC] [--timeout SEC] [--attention FILE] LISTFILE
#
#   LISTFILE     one `owner/repo number` per line; `#` starts a comment,
#                blank lines are ignored
#   --interval   seconds between passes (default 480)
#   --timeout    overall limit in seconds (default 14400, i.e. 4 h)
#   --attention  file the attention lines are written to; it is truncated at
#                start (default LISTFILE.attention)
#
# Each pass runs `pr-status.sh -R owner/repo N --json` once per PR that is not
# finished yet and dispatches on `.state` and `.next.action`, never on prose:
#
#   .state MERGED                    done
#   merge                            pr-merge.sh -R owner/repo N; rc 0 enqueued
#                                    or merged, rc 1 gate shut (next pass
#                                    reads again), anything else: attention
#   wait, await-review,
#   await-checks, await-capacity     keep waiting
#   rules-unavailable, or a failed
#   pr-status.sh read                keep waiting once; on the second
#                                    consecutive pass: attention
#   anything else                    attention — request-review, a closed PR,
#                                    an action this script does not know
#
# A second `merge` for a PR whose earlier pr-merge.sh returned 0 is also an
# attention stop: the entry most likely left the merge queue, and re-queuing
# cancels a queue run that may still be in flight
# (references/merge-gate-watcher.md, "Re-queuing cancels the run already in
# flight"). pr-merge.sh --self-reviewed is never passed: the attestation is a
# statement about a diff somebody read, so request-review stops the sweep.
#
# An attention stop does not abort the pass: the remaining PRs are still read
# and merged, then the sweep exits. One log line per state change per PR, with
# a UTC timestamp; a poll that changes nothing prints nothing.
#
# Exit codes: 0 every PR merged (last line `ALL MERGED`), 2 usage or input
# error, 3 at least one PR needs attention, 4 overall timeout (the open PRs and
# their last action are printed).

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH

set -euo pipefail

# --version answers "which copy am I running" without diffing installations.
# Two installations can declare the SAME number while shipping different
# scripts (netresearch/git-workflow-skill#209 measured exactly that, and the
# missing flag read as a missing feature for a dozen merges). So the resolved
# path is printed beside the version: the number says what the copy claims to
# be, the path says which file actually answered.
#
# The version is read from the SKILL.md NEXT TO the script, never from a
# checkout elsewhere -- a cached copy must report the number it was packaged
# with, or the answer is worse than none. \042 and \047 are the quote
# characters by octal code, so this awk program contains no quote of its own
# to terminate the single-quoted string it lives in.
skill_version() {
    local here skill v
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    skill="$here/../SKILL.md"
    v="unknown"
    if [ -f "$skill" ]; then
        v="$(awk '/^[ \t]*version:/ {
                 s = $0
                 sub(/^[ \t]*version:[ \t]*/, "", s)
                 gsub(/[\042\047]/, "", s)
                 gsub(/[ \t\r]+$/, "", s)
                 if (s != "") { print s; exit }
             }' "$skill" 2>/dev/null)" || v=""
        [ -n "$v" ] || v="unknown"
    fi
    printf '%s %s\n' "$(basename "${BASH_SOURCE[0]}")" "$v"
    printf 'path: %s/%s\n' "$here" "$(basename "${BASH_SOURCE[0]}")"
}

INTERVAL=480; TIMEOUT=14400; ATTN=""; LIST=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'pr-sweep: %s\n' "$1" >&2; exit 2; }
need() { [ $# -ge 2 ] && [ -n "${2:-}" ] || die "$1 requires a value"; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

while [ $# -gt 0 ]; do
  case "$1" in
    --interval)  need "$@"; INTERVAL="$2"; shift 2 ;;
    --timeout)   need "$@"; TIMEOUT="$2"; shift 2 ;;
    --attention) need "$@"; ATTN="$2"; shift 2 ;;
    --version) skill_version; exit 0 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  [ -z "$LIST" ] || die "one list file only (got '$LIST' and '$1')"
        LIST="$1"; shift ;;
  esac
done

[ -n "$LIST" ] || die "usage: pr-sweep.sh [--interval SEC] [--timeout SEC] [--attention FILE] LISTFILE"
[ -f "$LIST" ] || die "list file not found: $LIST"
is_uint "$INTERVAL" || die "--interval must be a whole number of seconds (got '$INTERVAL')"
is_uint "$TIMEOUT"  || die "--timeout must be a whole number of seconds (got '$TIMEOUT')"
[ -n "$ATTN" ] || ATTN="$LIST.attention"

command -v jq >/dev/null || die "jq not found"
for s in pr-status.sh pr-merge.sh; do
  [ -x "$SCRIPT_DIR/$s" ] || die "$s not found next to this script"
done

# ------------------------------------------------------------ the list -----
PRS=()
declare -A SEEN=()
n=0
while IFS= read -r line || [ -n "$line" ]; do
  n=$((n + 1))
  line="${line%%#*}"
  r=""; num=""; extra=""
  read -r r num extra <<<"$line" || true
  [ -z "$r" ] && continue
  [ -n "$num" ] && [ -z "$extra" ] || die "$LIST:$n: expected 'owner/repo number', got '$line'"
  case "$r" in
    */*/*|/*|*/) die "$LIST:$n: '$r' is not owner/repo" ;;
    */*) ;;
    *) die "$LIST:$n: '$r' is not owner/repo" ;;
  esac
  is_uint "$num" || die "$LIST:$n: '$num' is not a PR number"
  key="$r#$num"
  [ -n "${SEEN[$key]:-}" ] && continue
  SEEN[$key]=1
  PRS+=("$key")
done < "$LIST"

# An empty list must not end in `ALL MERGED`: zero PRs merged is not every PR
# merged, and a sweep that was handed the wrong file would report success.
[ "${#PRS[@]}" -gt 0 ] || die "$LIST lists no pull requests"

: > "$ATTN" || die "cannot write the attention file $ATTN"

# ----------------------------------------------------------- the sweep -----
declare -A FINISHED=() LAST=() FAILS=() ENQUEUED=()
ERR="$(mktemp)"
trap 'rm -f "$ERR"' EXIT

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# One line per change of state, keyed per PR: the same state on the next poll
# prints nothing, so the log stays readable over hours and every line in it is
# news.
note() { # note <pr> <state> <text>
  if [ "${LAST[$1]:-}" != "$2" ]; then
    printf '%s %s %s\n' "$(ts)" "$1" "$3"
    LAST[$1]="$2"
  fi
}

ATTENTION=0
attention() { # attention <pr> <text>
  printf '%s %s\n' "${1/\#/ }" "$2" >> "$ATTN"
  printf '%s %s ATTENTION: %s\n' "$(ts)" "$1" "$2"
  LAST[$1]="attention"
  FINISHED[$1]="attention"
  ATTENTION=1
}

probe_failed() { # probe_failed <pr> <reason>
  FAILS[$1]=$(( ${FAILS[$1]:-0} + 1 ))
  if [ "${FAILS[$1]}" -ge 2 ]; then
    attention "$1" "pr-status.sh unreadable on two consecutive passes: $2"
  else
    note "$1" "probe-failed" "probe failed once, reading again next pass: $2"
  fi
}

sweep_one() { # sweep_one <owner/repo#N>
  local pr="$1" repo num out rc state action why mout
  repo="${pr%#*}"; num="${pr##*#}"

  rc=0
  out=$("$SCRIPT_DIR/pr-status.sh" -R "$repo" "$num" --json 2>"$ERR") || rc=$?
  if [ "$rc" -ne 0 ]; then
    probe_failed "$pr" "exit $rc: $(tail -n 1 "$ERR")"
    return
  fi
  if ! state=$(jq -er '.state' <<<"$out" 2>/dev/null) \
     || ! action=$(jq -er '.next.action' <<<"$out" 2>/dev/null); then
    probe_failed "$pr" "no .state/.next.action in the --json output"
    return
  fi
  why=$(jq -r '.next.why // ""' <<<"$out" 2>/dev/null) || why=""

  if [ "$state" = "MERGED" ]; then
    FAILS[$pr]=0
    FINISHED[$pr]="merged"
    note "$pr" "merged" "MERGED"
    return
  fi

  case "$action" in
    rules-unavailable)
      probe_failed "$pr" "NEXT: $action — $why" ;;
    wait|await-review|await-checks|await-capacity)
      FAILS[$pr]=0
      note "$pr" "$action" "waiting: NEXT: $action — $why" ;;
    merge)
      FAILS[$pr]=0
      if [ -n "${ENQUEUED[$pr]:-}" ]; then
        attention "$pr" "NEXT: merge again after pr-merge.sh returned 0 — the entry probably left the merge queue; read the timeline before re-queuing ($why)"
        return
      fi
      rc=0
      mout=$("$SCRIPT_DIR/pr-merge.sh" -R "$repo" "$num" 2>&1) || rc=$?
      case "$rc" in
        0) ENQUEUED[$pr]=1
           LAST[$pr]=""
           note "$pr" "merge-rc0" "pr-merge.sh rc=0: $(tail -n 1 <<<"$mout")" ;;
        1) LAST[$pr]=""
           note "$pr" "merge-rc1" "pr-merge.sh rc=1 (gate shut, reading again next pass): $(tail -n 1 <<<"$mout")" ;;
        *) attention "$pr" "pr-merge.sh rc=$rc: $(tail -n 1 <<<"$mout")" ;;
      esac ;;
    *)
      FAILS[$pr]=0
      attention "$pr" "NEXT: $action — $why" ;;
  esac
}

start=$(date +%s)
deadline=$((start + TIMEOUT))
printf '%s sweep of %d PR(s), interval %ss, timeout %ss, attention file %s\n' \
  "$(ts)" "${#PRS[@]}" "$INTERVAL" "$TIMEOUT" "$ATTN"

while :; do
  for pr in "${PRS[@]}"; do
    [ -n "${FINISHED[$pr]:-}" ] && continue
    sweep_one "$pr"
  done

  if [ "$ATTENTION" = "1" ]; then
    printf '%s stopped: %s PR(s) need attention, listed in %s\n' \
      "$(ts)" "$(wc -l < "$ATTN" | tr -d ' ')" "$ATTN"
    exit 3
  fi

  open=0
  for pr in "${PRS[@]}"; do
    [ "${FINISHED[$pr]:-}" = "merged" ] || open=$((open + 1))
  done
  if [ "$open" -eq 0 ]; then
    echo "ALL MERGED"
    exit 0
  fi

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    printf '%s TIMEOUT after %ss with %d PR(s) open:\n' "$(ts)" "$((now - start))" "$open"
    for pr in "${PRS[@]}"; do
      [ "${FINISHED[$pr]:-}" = "merged" ] || printf '  %s last: %s\n' "$pr" "${LAST[$pr]:-not read}"
    done
    exit 4
  fi

  left=$((deadline - now))
  sleep "$(( INTERVAL < left ? INTERVAL : left ))"
done
