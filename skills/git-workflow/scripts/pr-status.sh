#!/usr/bin/env bash
# pr-status.sh — one-shot, complete merge-readiness picture for a pull request,
# plus the next valid action.
#
# Why this exists: `mergeStateStatus: BLOCKED` never says *why*. Discovering the
# reason one API call at a time (checks, then rulesets, then threads, then the
# allowed merge methods, then the queue) burns round-trips and still misses
# gates — in one 40-PR rollout, 183 of 370 shell calls were PR-status probing,
# the rulesets endpoint was queried exactly once, and `copilot_code_review`
# blocked four merges by surprise.
#
# Two API calls on the green path: one GraphQL document for the PR, its
# checks, reviews, threads and the repository's merge configuration; one REST
# call for the effective branch rules (which is the only place rulesets show
# up). A review-blocked PR costs a third, admin-only call for classic branch
# protection, whose review gates (require_last_push_approval, approval count,
# code-owner reviews) no other endpoint exposes. Only a PR that ends the ladder
# at `investigate` pays for more REST reads: check-runs and check-suites, both
# paginated (one call per 100 entries), the compare API when a strict
# status-check rule exists, and classic protection when it was not read yet.
# They feed the evidence block printed under that NEXT line; with
# `--watch --ignore-action investigate` they are skipped on every poll.
#
# Usage:
#   pr-status.sh                      # PR for the current branch
#   pr-status.sh 123                  # PR number in the current repo
#   pr-status.sh -R owner/repo 123
#   pr-status.sh --json               # machine-readable, no prose
#   pr-status.sh --watch              # return on the FIRST actionable event
#   pr-status.sh --watch --ignore-action request-review
#                                     # hold through a standing action you have
#                                     # decided not to take (repeatable)
#
# --watch deliberately does not wait for every check to finish. It returns as
# soon as something can be worked on: a failing check, a new annotation, or all
# required checks concluded. Waiting for `pending == 0` means learning nothing
# until the slowest matrix job ends, long after the first failure was visible.
#
# --ignore-action exists for the standing state the first-event rule cannot
# serve (#165): when `.next.action` is already actionable at invocation and
# retrying cannot clear it — a request-review made unsatisfiable by an
# exhausted Copilot quota — every re-arm of --watch returns the same line
# within a second, and the watch cannot be used to wait for anything else.
# Naming that action holds the watch through it: the watch still returns on
# every OTHER actionable event, and once the checks settle while NEXT still
# names the ignored action it returns `SETTLED: NEXT is still the ignored
# action` (exit 0) instead of idling into the timeout. A new check failure
# still returns, except when the ignored action IS the CI action
# (fix-ci/triage-ci).
#
# Copilot review quota
#
# The quota is per ACCOUNT and per MONTH, but the only evidence a single pull
# request carries is an errored review body on its own head — a PR nobody ever
# requested a review on carries none at all, and used to be answered with a
# re-request command the exhausted quota rejects. So the wall proven on one PR
# is written to ${XDG_CACHE_HOME:-~/.cache}/pr-status/, one file per calendar
# month, and every later invocation reads it before offering that command.
# The month lives in the FILENAME, so a marker from an earlier month is ignored
# rather than carried over the reset; delete the file to undo the effect.
#
# When the wall stands, the documented fallback (review the diff yourself,
# note it in the PR, decide) can be put on the record so the merge gate reads
# it back: a PR comment BY THE PR AUTHOR containing the line
# `Self-review: <head-sha>` (at least the first 12 chars). The ladder honours it
# ONLY while the demanded bot review is unsatisfiable — quota wall, or two
# failed reviews on this head — and only in a run authenticated as the PR
# author; the attestation dies with the next push,
# because the sha stops matching. `pr-merge.sh --self-reviewed` posts the
# comment and merges in one step. This is an explicit operator assertion the
# tool reads back, not a state it claims to observe (#203).
#
# --json contract
#
# One object, and its field names are THIS SCRIPT'S — not the GraphQL names
# `gh pr view` uses. `mergeState`, not `mergeStateStatus`. `base`, not
# `baseRefName`. Guessing costs more than reading: jq answers a missing key
# with `null` and says nothing, so a loop waiting for
# `.mergeStateStatus == "CLEAN"` never fires and reads as "still running"
# forever. Top-level keys:
#
#   state mergeable mergeState draft number title repo author author_is_bot
#   viewer viewer_is_author attestation_available viewer_commits viewer_committed
#   authorship_complete commits_read commits_total
#   base head headOid cross_repository
#   checks checks_settled threads unresolved_threads
#   unanswered_comments unanswered_human unanswered_by unanswered_urls
#   body_freshness
#   reviewDecision reviews_on_head has_review_on_head coderabbit_on_head
#   coderabbit_retry_at sonar_new_issues
#   has_copilot_review_on_head copilot_latest_on_head_ok copilot_review_errored
#   copilot_error_count copilot_quota_hit copilot_quota_exhausted
#   self_review_on_head self_review_url
#   requested_reviewers
#   merge_methods auto_merge_allowed queue_active queue_entry
#   rulesets rules_fetched required_contexts undispatched unsigned
#   classic_protection last_push_rulesets awaiting_approval
#   next
#
# `checks` is {total,pass,fail,pending,skip,...} and `next` is
# {action,why,cmd} — the same two things the prose rendering leads with.
# On `investigate` only, `next.evidence` carries what the extra reads found
# (ruleset rules, classic branch protection, required contexts per reporting
# app, failed suites outside the rollup, pull_request rule parameters,
# candidates); it is never a verdict. On `fix-required-context`,
# `next.stale_contexts` lists each required context reported only by a
# superseded workflow run: {context, workflow, reported_in, newest_run}, the
# two runs as {run_id, run_number, event, created_at, url}.
#
# `body_freshness` is {edited_at, edited, head_committed_at, older_than_head}:
# the last edit of the PR body (its creation time when never edited, then
# `edited` is false) against the committer date of the head commit. It is
# information only and never changes `next`; the prose rendering prints a
# `body` line when `older_than_head` is true.
#
# Before writing a jq filter against any of these, consider whether --watch
# already answers the question; it usually does, and a hand-rolled poll loop is
# how the wrong field name gets guessed in the first place.
#
# tests/test_pr_status_json_contract.sh fails when this list and the emitted
# object drift apart, in either direction.

# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH

set -uo pipefail

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

# The jq programs of evaluate() and investigate_evidence() live next to this
# script (pr-status-evaluate.jq, pr-status-investigate.jq). A symlink to the
# script is followed to the real file.
script_path="${BASH_SOURCE[0]}"
while [ -L "$script_path" ]; do
  link="$(readlink "$script_path")"
  case "$link" in
    /*) script_path="$link" ;;
    *) script_path="$(dirname "$script_path")/$link" ;;
  esac
done
SCRIPT_DIR="$(CDPATH='' cd -P "$(dirname "$script_path")" && pwd)"

REPO=""; PR=""; JSON=0; WATCH=0; INTERVAL=20; MAXWAIT=3600; IGNORE=""

# Every action the watch loop returns on. --ignore-action accepts exactly
# these: any other value could never have fired the loop, so accepting one
# would let a typo behave as if the flag were absent. The waiting actions
# (wait, await-*, rules-unavailable) heartbeat instead of returning, so they
# are deliberately not in here. tests/test_pr_status_draft_watch.sh pins the
# two lists against every action literal this script and its .jq programs can
# emit — a new action must land in one of them.
ACTIONABLE="fix-ci triage-ci rerun-ci resolve-threads address-comments request-review rebase resolve-conflicts merge blocked none fix-signatures ready investigate approve-workflow-runs fix-required-context"

die() { printf 'pr-status: %s\n' "$1" >&2; exit 2; }

need() { [ $# -ge 2 ] && [ -n "${2:-}" ] || die "$1 requires a value"; }

in_list() { case " $1 " in *" $2 "*) return 0 ;; *) return 1 ;; esac; }
is_ignored() { in_list "$IGNORE" "$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo)  need "$@"; REPO="$2"; shift 2 ;;
    --json)     JSON=1; shift ;;
    --watch)    WATCH=1; shift ;;
    --interval) need "$@"; INTERVAL="$2"; shift 2 ;;
    --max-wait) need "$@"; MAXWAIT="$2"; shift 2 ;;
    --ignore-action) need "$@"
                     # Whitespace first: "fix-ci triage-ci" happens to be a
                     # substring of ACTIONABLE and would slip past in_list.
                     case "$2" in (*[[:space:]]*)
                       die "--ignore-action: one action per flag (got '$2')" ;;
                     esac
                     in_list "$ACTIONABLE" "$2" \
                       || die "--ignore-action: unknown action '$2' (one of: $ACTIONABLE)"
                     IGNORE="$IGNORE $2"; shift 2 ;;
    # Prints the whole leading comment block rather than a fixed line range:
    # a hard-coded range silently truncates --help the moment the header
    # grows, which is how a documented contract stops being visible.
    --version) skill_version; exit 0 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  PR="$1"; shift ;;
  esac
done

if [ -n "$IGNORE" ] && [ "$WATCH" = "0" ]; then
  die "--ignore-action is only meaningful with --watch"
fi

command -v gh  >/dev/null || die "gh not found"
command -v jq  >/dev/null || die "jq not found"
# Checked once here: a missing program would otherwise make every --watch poll
# read as an unreadable gate until --max-wait ran out.
for f in pr-status-evaluate.jq pr-status-investigate.jq; do
  [ -f "$SCRIPT_DIR/$f" ] || die "$SCRIPT_DIR/$f is missing; it ships beside pr-status.sh"
done

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || die "not in a repo; pass -R owner/repo"
fi
if [ -z "$PR" ]; then
  PR=$(gh pr view --repo "$REPO" --json number --jq .number 2>/dev/null) \
    || die "no PR for the current branch; pass a number"
fi
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

# This script speaks GitHub GraphQL and nothing else. A GitLab project reads
# host/group/project, which parses here without complaint and then dies deep in
# the query as a bare "GraphQL query failed" — and --watch heartbeats into its
# timeout on a query that can never succeed. Refuse it up front and name where
# the answer lives instead (#250).
case "$REPO" in
  */*/*)
    die "\"$REPO\" is not owner/repo. pr-status.sh is GitHub-only; for a GitLab merge request see references/pull-request-workflow.md § \"GitLab: the same gate with glab\"" ;;
esac
case "${OWNER}" in
  *.*)
    die "\"$OWNER\" looks like a host, not a GitHub owner. pr-status.sh is GitHub-only; for a GitLab merge request see references/pull-request-workflow.md § \"GitLab: the same gate with glab\"" ;;
esac

# --------------------------------------------------------- quota marker -----
# The Copilot review quota is account-wide and monthly; the evidence for it is
# not. It arrives as an error body on ONE pull request, and every other PR of
# that account looks untouched — so the ladder below kept offering a
# re-request command that the same exhausted quota would reject (observed on
# netresearch/maint#52 and #53, hours after the wall was proven on another
# repo). One file per calendar month carries the fact across invocations.
QUOTA_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/pr-status"
# The month is in the NAME, not in the mtime: any later write would refresh an
# mtime and make a marker outlive the reset it describes.
QUOTA_MARKER="$QUOTA_DIR/copilot-quota-exhausted-$(date -u +%Y-%m)"
# ... and the marker expires, because the wall does not last the month. Measured
# on one machine: recorded 2026-08-18, a normal Copilot review delivered
# 2026-08-29, the wall back ten minutes later. A marker believed until the month
# rolls over turns one transient error into weeks of suppressed bot review, and
# nothing re-probes. After the TTL the next run asks again and either re-arms it
# or leaves it gone (#255). remember_quota_hit() never rewrites an existing
# marker, so the mtime stays the moment the wall was first proven.
QUOTA_TTL_HOURS="${PR_STATUS_QUOTA_TTL_HOURS:-6}"
# Bounded wait of --watch after a rate-limited read that does not wait for the
# GraphQL reset (budget left, or the lookup failed). Settable for the tests,
# which cannot afford a minute per case.
RATE_LIMIT_WAIT="${PR_STATUS_RATE_LIMIT_WAIT:-60}"
# A value that is not a positive integer would skip both clamps below and
# reach sleep as is; it gets the default.
[[ "$RATE_LIMIT_WAIT" =~ ^[1-9][0-9]*$ ]] || RATE_LIMIT_WAIT=60

quota_marker_seen() {
  [ -f "$QUOTA_MARKER" ] || { echo false; return; }
  if [ -n "$(find "$QUOTA_MARKER" -mmin "+$((QUOTA_TTL_HOURS * 60))" 2>/dev/null)" ]; then
    rm -f "$QUOTA_MARKER" 2>/dev/null || :
    echo false; return
  fi
  echo true
}

# A delivered Copilot review is the only positive evidence the wall is gone.
# Acting on it beats waiting out the TTL: the very run that sees the review
# would otherwise still route to self-review.
forget_quota_hit() { rm -f "$QUOTA_MARKER" 2>/dev/null || :; }

# Best-effort by design: the marker only saves a wasted re-request, so a
# read-only or full cache directory must never turn a status query into a
# failure. Content is for the human who wonders where the verdict came from.
remember_quota_hit() {
  [ -f "$QUOTA_MARKER" ] && return 0
  mkdir -p "$QUOTA_DIR" 2>/dev/null || return 0
  printf 'copilot review quota exhausted; proven on %s#%s at %s\n' \
    "$REPO" "$PR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$QUOTA_MARKER" 2>/dev/null || return 0
}

# ---------------------------------------------------------------- data ------
# Swallows gh's chatter on success -- a deprecation notice is not this tool's
# news -- but re-emits it verbatim when the call FAILS, because that body is the
# only thing separating an expired token from a rate limit from a network drop.
# Callers point the operator at stderr for the cause; before this, stderr held
# nothing but `pr-status: GraphQL query failed`.
collect() {
  local out err rc
  err=$(mktemp)
  out=$(collect_raw 2>"$err"); rc=$?
  [ "$rc" -eq 0 ] || cat "$err" >&2
  rm -f "$err"
  printf '%s' "$out"
  return "$rc"
}

collect_raw() {
  # shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variables, not shell
  gh api graphql -f owner="$OWNER" -f name="$NAME" -F pr="$PR" -f query='
  query($owner:String!,$name:String!,$pr:Int!){
    # Who is running this. Needed only for a bot-authored pull request, where
    # the answering party is the reviewer rather than the author (#319). Costs
    # no extra call: it rides along in the query that was going out anyway.
    viewer{ login }
    repository(owner:$owner,name:$name){
      nameWithOwner
      mergeCommitAllowed rebaseMergeAllowed squashMergeAllowed autoMergeAllowed
      # A merge queue set up through classic branch protection has no ruleset,
      # so the rules endpoint never lists it, queue_active read false, and
      # pr-merge.sh passed --delete-branch into a queue that refuses it
      # (glpi-docker-compose-stack#41). The mergeQueue field of the pull request
      # is the queue of its base branch; it rides along here at no extra call.
      # No apostrophes in these comments: the query is a single-quoted string.
      pullRequest(number:$pr){
        number title state isDraft mergeable mergeStateStatus reviewDecision
        mergeQueue{ id }
        mergeQueueEntry{ state position estimatedTimeToMerge }
        author{login __typename}
        baseRefName headRefName headRefOid isCrossRepository
        # When the body was last written, against committedDate of the head
        # below: see body_freshness. lastEditedAt is null for a body nobody
        # edited, and createdAt is then when it was written.
        createdAt lastEditedAt
        # The last page, not the first: a Self-review attestation (see the
        # header) is posted at the end of a conversation, and an old page
        # would go blind on exactly the PRs long enough to need one.
        comments(last:100){ nodes{ author{login __typename} body url createdAt lastEditedAt } }
        reviews(last:50){ nodes{ author{login} state commit{oid} body } }
        reviewRequests(first:20){ nodes{ requestedReviewer{
          ... on User{login} ... on Bot{login} ... on Team{slug} } } }
        reviewThreads(first:100){ nodes{ id isResolved isOutdated
          comments(first:1){ nodes{ databaseId author{login} path } } } }
        # One unsigned commit anywhere on the branch shuts a required_signatures
        # ruleset, and GitHub surfaces that only as mergeStateStatus BLOCKED —
        # no red check, nothing in the rollup. Without this the tool can only
        # say "investigate".
        # authors: who wrote each commit, so a non-author who pushed fixes is
        # not told to approve what they wrote themselves (retro-skill#164);
        # parents: a merge commit brings the base in and holds no code of theirs.
        # totalCount on both says whether the first page held everything.
        allCommits: commits(first:100){ totalCount nodes{ commit{ oid signature{ isValid }
          parents{ totalCount } authors(first:10){ totalCount nodes{ user{ login } } } } } }
        commits(last:1){ nodes{ commit{ oid committedDate statusCheckRollup{ state
          contexts(first:100){ pageInfo{ hasNextPage } nodes{
            __typename
            # checkSuite.workflowRun names the Actions run each row came from.
            # It is what tells a required context reported only by an OLDER
            # run of a workflow apart from one the newest run reported; see
            # $stale_required below. Null for a check run of any other app.
            # steps and annotations identify a failed Actions job that no
            # runner ever picked up; see NOSTART below.
            ... on CheckRun{ name conclusion status detailsUrl startedAt
              steps(first:1){ totalCount }
              annotations(first:10){ nodes{ message } }
              checkSuite{ status workflowRun{ databaseId runNumber event createdAt url
                workflow{ databaseId name } } } }
            ... on StatusContext{ context state targetUrl }
          } } } } } }
      }
    }
  }'
}

# A branch legitimately has no rules and answers `[]`, so an empty result is NOT
# an error — but a failed call must never be folded into the same value:
# "could not fetch" silently becoming "no required checks" would make this tool
# report a PR as more mergeable than it is, the one direction it must not get
# wrong. The fetch is inline rather than a function because a `$( )` subshell
# would discard the status flag.

evaluate() {
  local gql="$1" rules="$2" ok="$3" marker="$4" prot="${5:-null}" runs="${6:-[]}"
  # The jq program comes from a file and the JSON payloads from stdin, not
  # argv. Linux caps one argument at 128 KiB, which a pull request with long
  # comments passes; Windows caps the whole command line at 32767 characters,
  # which the program alone passes (#395). The program takes exactly four
  # documents and fails on any other count, so an empty rules answer stays an
  # error instead of reading as "no rules".
  printf '%s\n' "$gql" "$rules" "$prot" "$runs" \
    | jq -n --argjson ok "$ok" --argjson marker "$marker" --arg marker_path "$QUOTA_MARKER" \
         -f "$SCRIPT_DIR/pr-status-evaluate.jq"
}

# ------------------------------------------------------- investigate --------
# `investigate` used to be one sentence, and the reader then guessed a cause
# and reported it as fact (t3x-nr-image-optimize#201: BLOCKED, 72 checks pass,
# 0 fail, 0 threads, APPROVED). This gathers what can be read about the rest
# and lists it: the ruleset rules on the base branch, the classic branch
# protection (reviews, conversation resolution, signatures, admin enforcement,
# status checks), each required context with the app that reported it, failed
# check suites the GraphQL rollup does not show, and the pull_request rule
# parameters. It never names a cause. A parameter this script cannot evaluate
# is listed as set and not evaluable, nothing more.
#
# Called only on the investigate path, so the common path costs nothing. A
# failed read is carried as not fetched rather than folded into an empty list:
# "could not read the check-runs" must not print as "nothing is missing". Each
# read affects only the lines built from it.

# Classic branch protection, read into PROT / PROT_STATE / PROT_ERR. Called
# directly, never in $( ), so the three values survive. "not protected" is the
# 404 "Branch not protected" GitHub answers for a branch without classic
# protection; every other failure (the plain 404 "Not Found" a caller without
# admin rights gets, a 403, a network error) is "failed" and keeps the message.
PROT='null'; PROT_STATE='not requested'; PROT_ERR=''
read_protection() {
  local enc="$1" perr raw
  perr=$(mktemp)
  if raw=$(gh api "repos/$REPO/branches/$enc/protection" 2>"$perr") \
     && jq -e 'type == "object"' <<<"$raw" >/dev/null 2>&1; then
    PROT="$raw"; PROT_STATE='read'; PROT_ERR=''
  elif grep -q 'Branch not protected' "$perr" && grep -q 'HTTP 404' "$perr"; then
    PROT='null'; PROT_STATE='not protected'; PROT_ERR=''
  else
    PROT='null'; PROT_STATE='failed'
    PROT_ERR=$(grep -v '^[[:space:]]*$' "$perr" | tail -n 1 | sed 's/^gh: //')
    [ -n "$PROT_ERR" ] || PROT_ERR='no error message'
  fi
  rm -f "$perr"
}

investigate_evidence() {
  local g="$1" r="$2" prot="$3" prot_state="$4" prot_err="$5" enc="$6" head_oid="$7"
  # The check-runs and check-suites travel through files, not arguments: one
  # argument is capped at 128 KiB, and a head with several hundred check-runs
  # passed that even after trimming them to the fields used below.
  local tmp raw cr_ok=false cs_ok=false cmp='null' cmp_state='"not needed"'
  tmp=$(mktemp -d) || return 1
  if raw=$(gh api --paginate "repos/$REPO/commits/$head_oid/check-runs?per_page=100" 2>/dev/null) \
     && jq -sc '[.[].check_runs[]? | {name, status, conclusion, started_at,
                                     app: {id: .app.id}, check_suite: {id: .check_suite.id}}]' \
          <<<"$raw" >"$tmp/cr" 2>/dev/null; then cr_ok=true; else echo null >"$tmp/cr"; fi
  if raw=$(gh api --paginate "repos/$REPO/commits/$head_oid/check-suites?per_page=100" 2>/dev/null) \
     && jq -sc '[.[].check_suites[]? | {id, conclusion, app: {id: .app.id, slug: .app.slug}}]' \
          <<<"$raw" >"$tmp/cs" 2>/dev/null; then cs_ok=true; else echo null >"$tmp/cs"; fi
  raw=''
  # By sha, not by branch name: the GraphQL read does not carry the head
  # owner, and a fork branch name would be looked up in the wrong repository.
  # Asked when either source demands an up-to-date branch: a strict ruleset
  # rule, or strict status checks in classic protection.
  if jq -e '[.[]? | select(.type == "required_status_checks")
             | .parameters.strict_required_status_checks_policy // false] | any' <<<"$r" >/dev/null 2>&1 \
     || jq -e '.required_status_checks.strict // false' <<<"$prot" >/dev/null 2>&1; then
    if raw=$(gh api "repos/$REPO/compare/$enc...$head_oid" 2>/dev/null) \
       && cmp=$(jq -c '{behind_by, ahead_by}' <<<"$raw" 2>/dev/null); then cmp_state='"read"'
    else cmp='null'; cmp_state='"failed"'; fi
  fi
  # Through stdin for the same reason as in evaluate(): argv caps one argument
  # on Linux and the whole command line on Windows.
  printf '%s\n' "$g" "$r" "$prot" \
    | jq -n --arg prot_state "$prot_state" --arg prot_err "$prot_err" \
        --slurpfile crf "$tmp/cr" --slurpfile csf "$tmp/cs" --argjson cmp "$cmp" \
        --argjson cr_ok "$cr_ok" --argjson cs_ok "$cs_ok" --argjson cmp_state "$cmp_state" \
        -f "$SCRIPT_DIR/pr-status-investigate.jq"
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

render() {
  jq -r '
    "PR #\(.number)  \(.title)",
    "  state       : \(.state)\(if .draft then " (DRAFT)" else "" end)  mergeable=\(.mergeable)  mergeState=\(.mergeState)",
    "  head        : \(.headOid[0:8]) on \(.head) -> \(.base)",
    "  checks      : \(.checks.pass) pass, \(.checks.fail) fail, \(.checks.pending) pending\(if .checks.pending > 0 then " (\(.checks.running) running, \(.checks.queued) queued)" else "" end), \(.checks.skip) skip (of \(.checks.total))",
    (if (.checks.failing|length) > 0 then "  failing     : \(.checks.failing|join(", "))" else empty end),
    (if (.checks.cancelled|length) > 0 then "  cancelled   : \(.checks.cancelled|join(", ")) — re-run, do not debug" else empty end),
    (if ((.checks.not_started // [])|length) > 0 then "  not started : \(.checks.not_started|join(", ")) — no runner acquired; gh run rerun <run> --failed once that run has completed (run \(.checks.not_started_runs|map(tostring)|join(", "))), do not debug" else empty end),
    (if .checks.stale > 0 then "  stale       : \(.checks.stale) cancelled row(s) from a superseded run, ignored" else empty end),
    (if (.checks.failing_required|length) > 0 then "  ^ REQUIRED  : \(.checks.failing_required|join(", "))" else empty end),
    "  rulesets    : \(if (.rulesets|length)>0 then (.rulesets|join(", ")) else "none" end)",
    (if .classic_protection then
       "  classic     : approvals>=\(.classic_protection.approvals_required)\(if .classic_protection.last_push_approval then ", last-push-approval" else "" end)\(if .classic_protection.code_owner_reviews then ", code-owner-reviews" else "" end) (classic branch protection — invisible to the rulesets endpoint)"
     else empty end),
    "  reviews     : \(if .has_review_on_head then (.reviews_on_head|to_entries|map("\(.key)=\(.value)")|join(", ")) else "NONE on current head" end)\(if .coderabbit_on_head == "none" then "" else "  coderabbit=\(.coderabbit_on_head)\(if .coderabbit_retry_at then " (request again after \(.coderabbit_retry_at))" else "" end)" end)  decision=\(if .reviewDecision=="" then "-" else .reviewDecision end)",
    (if (.sonar_new_issues // 0) > 0 then
       "  sonar       : \(.sonar_new_issues) new issue(s) in the latest Quality Gate comment — not gating; read them before merging, a passed gate still lets them through"
     else empty end),
    "  threads     : \(.unresolved_threads) unresolved",
    (if .unanswered_comments > 0 then
       "  comments    : \(.unanswered_comments) unanswered (\(.unanswered_by|join(", ")))\(if .unanswered_human == 0 then " — bots only, not gating" else "" end)"
     else empty end),
    (if .body_freshness.older_than_head == true then
       "  body        : \(if .body_freshness.edited then "last edited" else "written" end) \(.body_freshness.edited_at), head committed \(.body_freshness.head_committed_at) — re-read the body against the diff"
     else empty end),
    "  merge       : methods=[\(.merge_methods|join(","))] auto=\(.auto_merge_allowed) queue=\(.queue_active)",
    (if .queue_entry then
       "  in queue    : position \(.queue_entry.position), \(.queue_entry.state)\(if (.queue_entry.eta != null) then ", ~\(((.queue_entry.eta) / 60) | floor) min" else "" end)"
     else empty end),
    "",
    "NEXT: \(.next.action) — \(.next.why)",
    (if .next.method then "  method: \(.next.method)" else empty end),
    (if .next.note   then "  note  : \(.next.note)"   else empty end),
    (if .next.cmd    then "  cmd   : \(.next.cmd)"    else empty end),
    (if .next.stale_contexts then (.next.stale_contexts[]
       | "  stale ctx   : \(.context) — \(.workflow) run #\(.reported_in.run_number) \(.reported_in.url // "")"
         + " superseded by run #\(.newest_run.run_number) \(.newest_run.url // "")") else empty end),
    (if .next.threads then (.next.threads[]|"  thread \(.threadId) (comment \(.commentId)) by \(.author) on \(.path)") else empty end),
    (if .next.urls then (.next.urls[]|"  \(.)") else empty end),
    (if .next.evidence then (.next.evidence as $e
      | "",
        "EVIDENCE — cause NOT determined; candidates, not a verdict",
        "  rules       : rulesets: \(if ($e.rules|length) > 0 then ($e.rules|map("\(.type)(\(.ruleset_id))")|join(", ")) else "none" end)",
        ($e.classic_protection as $c
         | if $c.fetched == "read" then
             "  classic prot: read — \(if $c.required_pull_request_reviews == null then "no pull request reviews required"
                                     else ($c.required_pull_request_reviews | "approvals \(.approvals_on_head)/\(.required_approving_review_count), dismiss_stale_reviews=\(.dismiss_stale_reviews), code_owner_reviews=\(.require_code_owner_reviews), last_push_approval=\(.require_last_push_approval)") end), conversation_resolution=\($c.required_conversation_resolution), signatures=\($c.required_signatures), enforce_admins=\($c.enforce_admins), status checks \(if $c.required_status_checks == null then "none" else "strict=\($c.required_status_checks.strict) (\($c.required_status_checks.contexts|join(", ")))" end)"
           elif $c.fetched == "not protected" then "  classic prot: none — the base branch has no classic protection"
           else "  classic prot: not fetched — \($c.error // $c.fetched)" end),
        ($e.status_check_rules[] | "  status rule : \(.source) strict=\(.strict)\(if .strict then " behind_by=\(.behind_by // "unreadable")" else "" end)"),
        (if $e.fetched.check_runs | not then "  contexts    : check-runs could not be read — per-context state unknown" else empty end),
        # An unknown context is not a finding of its own: the one candidate is
        # the failed read, so these rows carry "?" rather than FLAG.
        ($e.required_contexts[] | "  \(if .flag == null then "ok  " elif .flag == "unknown" then "?   " else "FLAG" end)        : \(.context) — required app \(.required_integration_id), reported by \(if .reported_by_apps == null then "unknown" elif (.reported_by_apps|length) == 0 then "nobody" else (.reported_by_apps|map(tostring)|join(",")) end), \(.state)\(if .flag != null then " [\(.flag)]" else "" end) (\(.source))"),
        (if $e.failed_suites_outside_rollup == null then "  suites      : check suites could not be read"
         elif ($e.failed_suites_outside_rollup|length) == 0 then "  suites      : no failed check suite outside the rollup"
         else ($e.failed_suites_outside_rollup[]
               | "  suite       : \(.suite_id) (\(.app // "unknown app")) \(.conclusion), "
                 + (if .outside_rollup != null then "outside the rollup: \(.outside_rollup|join(", "))"
                    else "runs \(if .check_runs == null then "unknown" else (.check_runs|join(", ")) end), \(.rollup_comparison)" end)) end),
        ($e.pull_request_rules[] | "  pr rule     : ruleset \(.ruleset_id) approvals \(.approvals_on_head)/\(.required_approving_review_count)\(if (.approvers|length) > 0 then " (\(.approvers|join(", ")))" else "" end), last_push_approval=\(.require_last_push_approval), extra_approval_for_unattributed_changes=\(.require_extra_approval_for_unattributed_changes), code_owner_review=\(.require_code_owner_review), thread_resolution=\(.required_review_thread_resolution)"),
        ($e.candidates[] | "  candidate   : \(.)"),
        "  summary     : \($e.summary)")
     else empty end)
  '
}

snapshot() {
  local g r base st
  g=$(collect) || die "GraphQL query failed"

  # GitHub computes mergeStateStatus lazily: the first read of a PR often
  # answers UNKNOWN and only schedules the calculation. Every gate decision
  # below (BEHIND, CLEAN, UNSTABLE) depends on it, so ask again once rather
  # than reporting a verdict built on UNKNOWN.
  st=$(jq -r '.data.repository.pullRequest.mergeStateStatus // "UNKNOWN"' <<<"$g")
  if [ "$st" = "UNKNOWN" ] &&
     [ "$(jq -r '.data.repository.pullRequest.state' <<<"$g")" = "OPEN" ]; then
    sleep 2
    g=$(collect) || die "GraphQL query failed"
  fi

  base=$(jq -r '.data.repository.pullRequest.baseRefName // "main"' <<<"$g")

  local enc r ok out
  enc=$(printf '%s' "$base" | jq -sRr @uri)
  # A private repository on a plan without branch rules answers 403 "Upgrade to
  # GitHub Pro or make this repository public". That is not an unreadable gate:
  # no ruleset and no protection can exist there, so the required list is empty
  # by construction and the verdict rests on mergeStateStatus and the checks.
  # Every other failure still means "unknown" (claude-code-marketplace-P#8).
  local rerr
  rerr=$(mktemp)
  if r=$(gh api "repos/$REPO/rules/branches/$enc" 2>"$rerr"); then ok=1
  elif grep -q 'Upgrade to GitHub Pro' "$rerr" && grep -q 'HTTP 403' "$rerr"; then ok=1; r='[]'
  else ok=0; r='[]'; fi
  rm -f "$rerr"

  # Classic branch protection holds review gates the rules endpoint never
  # shows (require_last_push_approval, approval count, code-owner reviews;
  # go-cron#399 sat review-blocked with every visible gate green because of
  # one). Admin-only endpoint: a 403/404 leaves it null and the ladder says
  # nothing. Fetched lazily — only when the PR is BLOCKED or a review is
  # demanded — so the common green path keeps its two API calls.
  local st2 rd
  st2=$(jq -r '.data.repository.pullRequest.mergeStateStatus // ""' <<<"$g")
  rd=$(jq -r '.data.repository.pullRequest.reviewDecision // ""' <<<"$g")
  if [ "$st2" = "BLOCKED" ] || [ "$rd" = "REVIEW_REQUIRED" ] || [ "$rd" = "CHANGES_REQUESTED" ]; then
    read_protection "$enc"
  fi

  # A fork pull request's workflow runs need a maintainer's approval after
  # every new SHA, and an unapproved run is invisible in the check rollup
  # (#310). Fetched only when the head is cross-repository, so a same-repo PR
  # keeps its existing call count. A failed call leaves the list empty, which
  # understates rather than invents — the same direction the rules fetch takes.
  local runs='[]' head_oid rr
  if [ "$(jq -r '.data.repository.pullRequest.isCrossRepository // false' <<<"$g")" = "true" ]; then
    head_oid=$(jq -r '.data.repository.pullRequest.headRefOid // ""' <<<"$g")
    if [ -n "$head_oid" ] && rr=$(gh api "repos/$REPO/actions/runs?head_sha=$head_oid&per_page=100" 2>/dev/null); then
      runs=$(jq -c '[.workflow_runs[]?
                     | select(.status == "action_required" or .conclusion == "action_required")
                     | {id: .id, name: .name}]' <<<"$rr") || runs='[]'
    fi
  fi

  out=$(evaluate "$g" "$r" "$ok" "$(quota_marker_seen)" "$PROT" "$runs")
  # Written from the EVIDENCE field, never from the verdict: with
  # copilot_quota_exhausted the marker would re-assert itself, and the PR named
  # inside it would be whichever one read the file rather than the one that
  # proved the wall — the single thing the content is there to answer.
  # Order decides, so this is asked FIRST: an errored quota row and a delivered
  # review can both sit on the same head, and then copilot_quota_hit alone would
  # re-arm the marker although the wall has since lifted (#255).
  if [ "$(jq -r '.copilot_latest_on_head_ok // false' <<<"$out")" = "true" ]; then
    forget_quota_hit
  elif [ "$(jq -r '.copilot_quota_hit // false' <<<"$out")" = "true" ]; then
    remember_quota_hit
  fi
  # The extra reads happen only here, on the one rung that explains nothing.
  # If building the evidence fails, the verdict still stands, and the why says
  # the evidence is absent rather than pointing at a block that is not there.
  # Under --watch with investigate ignored, the watch never returns on it, so
  # gathering the evidence on every poll would only spend API calls.
  if [ "$(jq -r '.next.action' <<<"$out")" = "investigate" ] \
     && [ "$WATCH" = "1" ] && is_ignored investigate; then
    out=$(jq -c '.next.why += " (evidence not gathered: investigate is ignored under --watch)"' <<<"$out")
  elif [ "$(jq -r '.next.action' <<<"$out")" = "investigate" ]; then
    local ev
    # Protection is read lazily above; investigate can be reached from a
    # merge state that did not trigger that read.
    [ "$PROT_STATE" = "not requested" ] && read_protection "$enc"
    if ev=$(investigate_evidence "$g" "$r" "$PROT" "$PROT_STATE" "$PROT_ERR" "$enc" "$(jq -r '.headOid' <<<"$out")") \
       && [ -n "$ev" ]; then
      # Both through stdin: the evidence block grows with the required checks
      # and the failed suites, and passes 32767 characters at about 135
      # required contexts.
      out=$(printf '%s\n' "$out" "$ev" | jq -cn 'input as $o | input as $ev | $o
             | .next.evidence = $ev
             | .next.why += " — the evidence below lists what was read and the remaining candidates, none of them a verdict"')
    else
      out=$(jq -c '.next.why += " (the evidence block could not be built; cause on stderr above)"' <<<"$out")
    fi
  fi
  printf '%s\n' "$out"
}

emit() {
  if [ "$JSON" = "1" ]; then jq . <<<"$1"; else render <<<"$1"; fi
}

# ---------------------------------------------------------------- run -------
if [ "$WATCH" = "0" ]; then
  # Same reason as the --watch branch below: `die` inside snapshot() runs in
  # this command substitution's subshell, so a failed GraphQL read left $s
  # empty and this path went on to `exit 0`. A caller keying on the exit
  # status — a hook, a Makefile, a monitor — then read a failed gate read as a
  # passed gate, and `--json` handed an empty string to whatever parses it.
  if ! s=$(snapshot) || [ -z "$s" ] || ! jq -e '.next.action' <<<"$s" >/dev/null 2>&1; then
    die "could not read the gate for ${REPO}#${PR}; cause on stderr above"
  fi
  emit "$s"
  exit 0
fi

# Watch: stop at the first thing that can be acted on, not at full settle.
start=$(date +%s); seen_fail=""
while :; do
  # A snapshot that could not be read is its own branch, not "still waiting".
  # `die` inside $( ) kills only the subshell, so a failed collect left $s
  # empty, printed its reason to stderr -- where a watcher harness never turns
  # it into an event -- and then emitted a bare `waiting:` on stdout every
  # interval. The operator could not tell a quiet gate from a broken query and
  # killed a watch that was reporting nothing (observed during a GraphQL user
  # rate limit, netresearch/typo3-ci-workflows#250).
  # snapshot's stderr goes through a file so the failed read's cause, which
  # collect() already re-emits, can be classified below without a second call.
  # It is passed on to stderr unchanged, success or not.
  snap_err=$(mktemp)
  snap_ok=1
  s=$(snapshot 2>"$snap_err") || snap_ok=0
  cat "$snap_err" >&2
  if [ "$snap_ok" = "0" ] || [ -z "$s" ] || ! jq -e '.next.action' <<<"$s" >/dev/null 2>&1; then
    rate_limited=0
    # The forms GitHub sends for a rate limit, and only those: a message that
    # merely mentions a limit (a missing `rate_limit` scope, say) keeps the
    # interval retry.
    { grep -qE 'RATE_LIMIT' "$snap_err" || grep -qiE 'API rate limit|secondary rate limit' "$snap_err"; } && rate_limited=1
    rm -f "$snap_err"
    elapsed=$(($(date +%s) - start))
    if [ "$elapsed" -ge "$MAXWAIT" ]; then
      echo "TIMEOUT after ${MAXWAIT}s — the gate stayed unreadable"
      exit 1
    fi
    # `pr-status:` prefix deliberately: the documented watcher filter in
    # references/merge-gate-watcher.md keeps ACTIONABLE/TIMEOUT/SETTLED/NEXT and
    # this tool's own `pr-status:` diagnostics, and drops everything else. An
    # unprefixed line would be filtered out and leave the consumer in exactly
    # the silent state this branch exists to end.
    if [ "$rate_limited" = "1" ]; then
      # Retrying every interval into a rate limit keeps it engaged: three reads
      # 20 s apart all failed with graphql_rate_limit while `rate_limit` showed
      # budget left (2026-09-29). An exhausted budget (remaining 0) lifts at the
      # GraphQL reset, so sleep to it in one go. Budget left means a secondary
      # limit: the counter does not show it, its reset field is merely the end
      # of the hourly window, and it usually lifts within a minute -- a bounded
      # 60 s. So does a lookup that fails. Never shorter than the interval,
      # never past --max-wait, measured after the lookup.
      lookup=(gh api rate_limit --jq '.resources.graphql | "\(.remaining) \(.reset)"')
      command -v timeout >/dev/null 2>&1 && lookup=(timeout 15 "${lookup[@]}")
      remaining="" reset=""
      read -r remaining reset < <("${lookup[@]}" 2>/dev/null || true) || true
      now=$(date +%s)
      elapsed=$((now - start))
      if [ "$elapsed" -ge "$MAXWAIT" ]; then
        echo "TIMEOUT after ${MAXWAIT}s — the gate stayed unreadable"
        exit 1
      fi
      if [[ "$remaining" =~ ^[0-9]+$ ]] && [ "$remaining" -eq 0 ] \
        && [[ "$reset" =~ ^[0-9]+$ ]] && [ "$reset" -gt "$now" ]; then
        rl_wait=$((reset - now + 1))
        rl_until="the GraphQL reset at $(jq -rn --argjson t "$reset" '$t | todate')"
      elif [[ "$remaining" =~ ^[0-9]+$ ]] && [ "$remaining" -gt 0 ]; then
        rl_wait=$RATE_LIMIT_WAIT
        rl_until="a bounded ${rl_wait}s (GraphQL budget left: a secondary limit)"
      else
        rl_wait=$RATE_LIMIT_WAIT
        rl_until="a bounded ${rl_wait}s (GraphQL budget unreadable or reset already past)"
      fi
      [ "$rl_wait" -lt "$INTERVAL" ] && rl_wait=$INTERVAL
      [ "$rl_wait" -gt $((MAXWAIT - elapsed)) ] && rl_wait=$((MAXWAIT - elapsed))
      echo "pr-status: UNREADABLE — GitHub rate limit on ${REPO}#${PR}; cause on stderr above. Waiting ${rl_wait}s for ${rl_until} instead of retrying every ${INTERVAL}s."
      sleep "$rl_wait"
      continue
    fi
    echo "pr-status: UNREADABLE — cannot read the gate for ${REPO}#${PR}; cause on stderr above. Retrying in ${INTERVAL}s."
    sleep "$INTERVAL"
    continue
  fi
  rm -f "$snap_err"
  act=$(jq -r '.next.action' <<<"$s")
  # Not-started rows are left out: they are answered by NEXT (rerun-ci once
  # their run has concluded, wait before), not by a check-failed return.
  fails=$(jq -r '.checks.failing_other|join(",")' <<<"$s")
  # A red REQUIRED check is actionable the moment it appears. A red
  # non-required one is not, while a required check is still running: it
  # cannot be what keeps the gate shut yet, and returning on it ends the watch
  # with nothing to do (#249). Hold until the required checks conclude — then
  # the same red check is the reason the gate stays shut, and this fires.
  fails_required=$(jq -r '.checks.failing_required_other|join(",")' <<<"$s")
  pending_required=$(jq -r '.checks.pending_required|length' <<<"$s")
  if [ -z "$fails_required" ] && [ "$pending_required" -gt 0 ]; then
    fails=""
  fi

  # The ignore test sits on this exit too, but ONLY when the standing action
  # the caller declined IS the CI action (fix-ci/triage-ci) — then its failing
  # checks are part of the state the caller already saw, not a fresh event.
  # Any other ignored action must not eat a failure: resolve-conflicts and
  # rebase outrank fix-ci in the NEXT ladder, so a red check can appear while
  # the action still names the ignored non-CI blocker.
  if [ -n "$fails" ] && [ "$fails" != "$seen_fail" ] \
     && ! { is_ignored "$act" && in_list "fix-ci triage-ci" "$act"; }; then
    seen_fail="$fails"
    echo "ACTIONABLE: check failed -> $fails"
    emit "$s"; exit 0
  fi
  # A CodeRabbit review in flight is a review the gate must wait for, and it
  # finishes on its own, so neither settled exit below may return over it.
  cr_busy=false
  [ "$(jq -r '.coderabbit_on_head' <<<"$s")" = "in-progress" ] && cr_busy=true
  if is_ignored "$act"; then
    # A standing action the caller has already seen and declined (#165): never
    # return on it. Once the checks settle, nothing about it will change
    # either — say so instead of idling into the timeout. The message claims
    # exactly what was checked: NEXT (the highest-priority action) is still
    # the ignored one — lower-ranked work may well remain in the snapshot.
    if [ "$(jq -r '.checks_settled' <<<"$s")" = "true" ] && [ "$cr_busy" = false ]; then
      echo "SETTLED: NEXT is still the ignored action -> $act"
      emit "$s"; exit 0
    fi
  elif [ "$act" = "request-review" ]; then
    # request-review while CI has not settled is not actionable yet — the
    # ladder itself stamps "do not enqueue on this reading" onto the why.
    # Keep waiting: a failing check fires the branch above, and once the
    # checks settle this returns on the review state (#186). The quota
    # dead-end holds here too: waiting cannot clear the quota, but the
    # checks are the thing that still moves, and returning early hands the
    # operator a manual re-arm for every push (observed twice on
    # 2026-08-18). It returns below once CI settles.
    if [ "$(jq -r '.checks_settled' <<<"$s")" != "true" ] || [ "$cr_busy" = true ]; then
      :
    # A request-review whose cause is an exhausted review bot is a standing
    # condition, not an event: waiting cannot clear a quota ceiling, so every
    # re-arm of --watch returns instantly with the same line. Saying so —
    # and naming the flag that holds through it — is what stops an operator
    # re-arming it three times before giving up on the tool.
    elif [ "$(jq -r '.copilot_quota_exhausted // false' <<<"$s")" = "true" ]; then
      echo "ACTIONABLE: request-review (UNSATISFIABLE — Copilot is OUT OF REVIEW QUOTA" \
           "for the month; this will NOT change until the monthly reset, on this or any" \
           "other PR. Checks are settled — do not re-request and do not re-arm, a" \
           "re-arm returns immediately with this same line. Review the diff yourself" \
           "and decide; to hold through this standing action for other reasons:" \
           "pr-status.sh -R $(jq -r '.repo' <<<"$s") $(jq -r '.number' <<<"$s") --watch --ignore-action request-review)"
    elif [ "$(jq -r '.copilot_error_count // 0' <<<"$s")" -ge 2 ]; then
      echo "ACTIONABLE: request-review (UNSATISFIABLE — the review bot has failed" \
           "$(jq -r '.copilot_error_count' <<<"$s")x on this head; re-arming this watch" \
           "returns immediately. Review the diff yourself, or wait for the checks:" \
           "pr-status.sh -R $(jq -r '.repo' <<<"$s") $(jq -r '.number' <<<"$s") --watch --ignore-action request-review)"
    else
      echo "ACTIONABLE: request-review"
    fi
    # Unsettled-CI hold: emit nothing, fall through to the wait line.
    # The quota dead-end returns only here, WITH the checks settled — a
    # re-arm on a settled PR still comes straight back with the same
    # UNSATISFIABLE line, which is what its message says.
    if [ "$(jq -r '.checks_settled' <<<"$s")" = "true" ] && [ "$cr_busy" = false ]; then
      emit "$s"; exit 0
    fi
  elif in_list "$ACTIONABLE" "$act"; then
    echo "ACTIONABLE: $act"
    emit "$s"; exit 0
  fi

  now=$(date +%s)
  if [ $((now - start)) -ge "$MAXWAIT" ]; then
    echo "TIMEOUT after ${MAXWAIT}s — still: $(jq -r '.next.why' <<<"$s")"
    emit "$s"; exit 1
  fi
  echo "waiting: $(jq -r '.next.why' <<<"$s")"
  sleep "$INTERVAL"
done
