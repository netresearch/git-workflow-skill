#!/usr/bin/env bash
# pr-merge.sh — merge a pull request with the method the repository allows,
# and only when the merge gate is actually open.
#
# Why this exists: `gh pr merge --merge --delete-branch` is wrong in several
# repository configurations and gives no useful error until it fails. Two of
# them answer with a message; the other two are silent. A repo
# with `allow_merge_commit: false` answers "Merge commits are not allowed on
# this repository"; a repo with a merge queue answers "Cannot use --delete-branch
# when merge queue enabled". Hand-rolling the detection per call site is how a
# 54-repository rollout hit both, three times each. The silent two are a fork
# head, which is not ours to delete, and a branch another open pull request is
# based on, whose deletion closes that pull request. pr-status.sh already knows
# most of the answer — this reads it instead of guessing.
#
# Squash is never used: it discards atomic commits and their signatures.
#
# Usage:
#   pr-merge.sh                       # PR for the current branch
#   pr-merge.sh 123
#   pr-merge.sh -R owner/repo 123
#   pr-merge.sh -R owner/repo 123 --dry-run   # print the command, run nothing
#   pr-merge.sh -R owner/repo 123 --retarget-stacked
#                                     # the repository deletes merged head
#                                     # branches itself (delete_branch_on_merge)
#                                     # and open pull requests are based on
#                                     # this one's head branch: retarget them
#                                     # to this pull request's base first, then
#                                     # merge. Without the flag the merge is
#                                     # refused (exit 2) with the commands.
#   pr-merge.sh -R owner/repo 123 --self-reviewed
#                                     # the review the gate demands is one an
#                                     # exhausted Copilot quota (or two failed
#                                     # reviews on this head) makes
#                                     # unsatisfiable, and the operator has
#                                     # reviewed the diff instead: post the
#                                     # on-the-record `Self-review: <head-sha>`
#                                     # attestation comment as the PR author,
#                                     # then merge. Refused whenever a live
#                                     # review path still exists, and whenever
#                                     # the authenticated gh user is not the
#                                     # PR author (#203).
#   pr-merge.sh -R owner/repo 123 --wait [--interval 20] [--max-wait 3600]
#                                     # stay instead of returning early, for at
#                                     # most --max-wait seconds in total (plus
#                                     # one read), reading every --interval:
#                                     # - while the gate answers a waiting step
#                                     #   (wait, await-review, await-checks,
#                                     #   await-capacity), re-read it until it
#                                     #   answers merge, then merge;
#                                     # - on a merge queue, until the entry has
#                                     #   merged or left the queue, also for an
#                                     #   entry that was queued before this
#                                     #   call (it is not enqueued again).
#                                     # With --dry-run nothing is waited for.
#   pr-merge.sh -R owner/repo 123 --wait --request-coderabbit
#                                     # also wait out a CodeRabbit rate limit:
#                                     # when the gate answers request-review
#                                     # with no review on the head while
#                                     # CodeRabbit refused THIS head as rate
#                                     # limited and its notice names the
#                                     # reset, wait until that time plus
#                                     # PR_MERGE_CODERABBIT_MARGIN seconds
#                                     # (default 60), reading the gate every
#                                     # max(--interval, 120 s), post ONE
#                                     # `@coderabbitai review` comment for the
#                                     # head, and keep waiting while that review
#                                     # runs; merge when the gate opens. Nothing
#                                     # is posted while a check runs or is red,
#                                     # when a request made after the reset is
#                                     # not refused by CodeRabbit, when the
#                                     # reset lies past --max-wait, nor on a
#                                     # draft (CodeRabbit does not review
#                                     # drafts; that is reported). Refused again
#                                     # at the same reset: exit 1.
#                                     # Only with --wait. pr-status.sh itself
#                                     # never posts; this flag is the one place
#                                     # the request is written.
#
# Exit codes: 0 merged (or queued) AND confirmed by reading the PR back.
# With --wait, 0 also when the PR merged while the gate was being waited for.
# 1 the gate is shut and nothing was attempted; with --wait also: the gate
# turned to a step that is not a waiting one, it still answered a waiting step
# when --max-wait ran out, the entry left the queue unmerged, or was still
# queued when --max-wait ran out.
# 2 an error — usage, lookup, the merge call itself failed, or it exited 0
# while nothing merged and nothing entered the queue; a merge that would close
# stacked pull requests (see --retarget-stacked); with --wait also: the last
# read of the gate or of the PR failed when --max-wait ran out; with
# --request-coderabbit also: the comment read before posting the review
# request, or the post itself, failed (never retried; a failed read while
# waiting after a request is not an outcome). 1 is retryable
# later; 2 needs a human.

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

REPO=""; PR=""; DRY=0; SELF_REVIEWED=0; RETARGET=0; WAIT=0; REQUEST_CR=0
WAIT_INTERVAL=20; WAIT_MAX=3600; WAIT_TUNED=0
# One read during --wait may take at most this long (the bound pr-status.sh
# puts on its own rate-limit lookup).
WAIT_READ_MAX=15
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'pr-merge: %s\n' "$1" >&2; exit 2; }
need() { [ $# -ge 2 ] && [ -n "${2:-}" ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo) need "$@"; REPO="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    --self-reviewed) SELF_REVIEWED=1; shift ;;
    --retarget-stacked) RETARGET=1; shift ;;
    --wait) WAIT=1; shift ;;
    --request-coderabbit) REQUEST_CR=1; shift ;;
    --interval) need "$@"; WAIT_INTERVAL="$2"; WAIT_TUNED=1; shift 2 ;;
    --max-wait) need "$@"; WAIT_MAX="$2"; WAIT_TUNED=1; shift 2 ;;
    --version) skill_version; exit 0 ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  PR="$1"; shift ;;
  esac
done

if [ "$WAIT_TUNED" = "1" ] && [ "$WAIT" = "0" ]; then
  die "--interval and --max-wait only apply with --wait"
fi
for v in "$WAIT_INTERVAL" "$WAIT_MAX"; do
  # No leading zero: bash arithmetic reads 08 as an invalid octal number.
  [[ "$v" =~ ^(0|[1-9][0-9]*)$ ]] || die "--interval and --max-wait take whole seconds without a leading zero, got: $v"
done
[ "$WAIT_INTERVAL" -ge 1 ] || die "--interval must be at least 1"
if [ "$REQUEST_CR" = "1" ] && [ "$WAIT" = "0" ]; then
  die "--request-coderabbit only applies with --wait"
fi
# Seconds after the reset CodeRabbit's notice names before the request is
# posted: the notice counts in whole minutes from its last edit, so a request
# sent on the second can still be refused. Settable for the tests.
CR_MARGIN="${PR_MERGE_CODERABBIT_MARGIN:-60}"
[[ "$CR_MARGIN" =~ ^(0|[1-9][0-9]*)$ ]] || CR_MARGIN=60

# A GitLab merge request (host/group/project, #331) is read by pr-status.sh,
# but this script merges with gh only. Refuse before anything is called and
# name the command pr-status.sh prints for it.
case "$REPO" in
  */*/*)
    case "${REPO%%/*}" in
      *.*) die "$REPO is a GitLab project; pr-merge.sh merges GitHub pull requests only. Read the gate with pr-status.sh -R $REPO ${PR:-<iid>} and run the cmd it prints on NEXT: merge" ;;
      *) ;;
    esac ;;
  *) ;;
esac

command -v gh >/dev/null || die "gh not found"
command -v jq >/dev/null || die "jq not found"
[ -x "$SCRIPT_DIR/pr-status.sh" ] || die "pr-status.sh not found next to this script"

# With "soft" (the re-reads of --wait), a failed read returns 1 and leaves
# every variable as the previous read set it: one failed read is not a gate
# state. Without it, a failed read ends the script with exit 2.
read_status() {
  local soft="${1:-}" st fields a w r p q iq ps m c h b
  if ! st=$("$SCRIPT_DIR/pr-status.sh" ${REPO:+-R "$REPO"} ${PR:+"$PR"} --json); then
    [ "$soft" = "soft" ] && return 1
    die "pr-status.sh failed"
  fi

  # Tab-separated, read with a tab-only IFS: the default IFS splits on spaces
  # too, which would tear `why` apart. A tab is still IFS whitespace, so an
  # empty field collapses and every later variable shifts by one — which is
  # why the fields that can be empty come last. `jq -e` turns a schema change
  # or truncated output into a failure here rather than an empty ACTION
  # further down.
  if ! fields=$(printf '%s' "$st" | jq -er '
    [ .next.action,
      (.next.why // "-"),
      .repo,
      (.number|tostring),
      (.queue_active|tostring),
      (.queue_entry != null | tostring),
      (.state // "-"),
      (.merge_methods|join(",")),
      (.cross_repository|tostring),
      (.head // ""),
      (.base // "")
    ] | @tsv'); then
    [ "$soft" = "soft" ] && return 1
    die "pr-status.sh returned unexpected JSON"
  fi

  IFS=$'\t' read -r a w r p q iq ps m c h b <<EOF
$fields
EOF
  if [ -z "$a" ] || [ -z "$r" ] || [ -z "$p" ]; then
    [ "$soft" = "soft" ] && return 1
    die "pr-status.sh returned no action"
  fi
  STATUS=$st; ACTION=$a; WHY=$w; REPO=$r; PR=$p; QUEUE=$q; INQUEUE=$iq
  PRSTATE=$ps; METHODS=$m; CROSS=$c; HEADREF=$h; BASEREF=$b
}

read_status

# --self-reviewed clears a review demand that the author may satisfy in person.
# Two refusals qualify: `review-required`, where the policy wants a review and
# does not care whose, and `bot-review-unsatisfiable`, where the demanded bot
# review cannot arrive at all. Both are demands for A review; neither is a
# host gate. A pending bot request is not on the list, because requesting a
# reviewer commits you to waiting for its answer, and pr-status.sh keeps the
# attestation inert while one is in flight.
#
# The flag does not open the gate directly — it posts the on-the-record
# `Self-review: <head-sha>` attestation comment pr-status.sh reads back, then
# asks again. Everything else about the gate stays exactly as strict: any
# other refusal, a non-author caller, or a live review path leaves the flag
# without effect.
if [ "$SELF_REVIEWED" = "1" ] && [ "$ACTION" = "request-review" ]; then
  SR_FIELDS=$(printf '%s' "$STATUS" | jq -er '
    [ (.next.reason // "-"),
      ((.self_review_on_head // false)|tostring),
      (.headOid // ""), (.author // ""),
      ((.author_is_bot // false)|tostring)
    ] | @tsv') || die "pr-status.sh returned unexpected JSON"
  IFS=$'\t' read -r SR_REASON SR_HAVE SR_HEAD SR_AUTHOR SR_AUTHOR_BOT <<EOF
$SR_FIELDS
EOF
  # Keyed on the reason the REFUSING BRANCH stamped, never re-derived from the
  # account-global quota state: a request-review can also come from e.g. the
  # classic require_last_push_approval gate — a satisfiable human approval —
  # and with the monthly quota marker set on this machine a global test would
  # post a factually false "unsatisfiable" attestation into permanent PR
  # history there.
  case "$SR_REASON" in
    review-required|bot-review-unsatisfiable) ;;
    *)
      die "--self-reviewed refused: this request-review is not one the author may satisfy in person (reason: $SR_REASON) — a live review path exists, use it" ;;
  esac
  # A bot-authored pull request can never satisfy the author check below, so
  # the generic refusal would send the operator looking for a way to become
  # renovate. Named separately, with the path that does exist: approving the
  # head as yourself satisfies the same gate, and pr-merge then merges without
  # any flag (#280). No relaxation — a third party still cannot mint an
  # attestation for someone else's pull request.
  if [ "$SR_AUTHOR_BOT" = "true" ]; then
    die "--self-reviewed refused: $SR_AUTHOR is a bot, and the attestation is an assertion by the PR author — a bot never reads the diff, so this flag has no meaning here. Review the diff and approve it as yourself: gh pr review $PR --repo $REPO --approve, then re-run this script without --self-reviewed."
  fi
  VIEWER=$(gh api user --jq .login 2>/dev/null) || die "--self-reviewed: could not resolve the authenticated gh user"
  if [ "$VIEWER" != "$SR_AUTHOR" ]; then
    die "--self-reviewed refused: the attestation must come from the PR author ($SR_AUTHOR); gh is authenticated as $VIEWER"
  fi
  if [ "$SR_HAVE" != "true" ]; then
    # The body states which of the two demands is being satisfied. Writing
    # "unsatisfiable" where the truth is "a review was required and I wrote it"
    # puts a false claim about a bot into permanent pull-request history.
    if [ "$SR_REASON" = "bot-review-unsatisfiable" ]; then
      WHY_TEXT='The bot review this pull request demands is unsatisfiable (Copilot quota wall or repeated bot failures on this head).'
    else
      WHY_TEXT='This pull request requires a review and no bot review is in flight; a review by the author satisfies that requirement.'
    fi
    BODY=$(printf 'Self-review: %s\n\n%s The diff on this head was reviewed by the PR author; this comment is the on-the-record attestation the merge gate reads back. It stops matching on the next push.' "$SR_HEAD" "$WHY_TEXT")
    if [ "$DRY" = "1" ]; then
      # A dry run must not flip persistent gate state: the attestation comment
      # IS the gate-opening write, so it is previewed, never posted.
      printf 'pr-merge: dry-run — would post the Self-review attestation for %s on %s#%s, re-read the gate and merge\n' "${SR_HEAD:0:12}" "$REPO" "$PR"
      exit 0
    fi
    gh pr comment "$PR" --repo "$REPO" --body "$BODY" >/dev/null \
      || die "--self-reviewed: posting the attestation comment failed"
    printf 'pr-merge: posted Self-review attestation for %s on %s#%s\n' "${SR_HEAD:0:12}" "$REPO" "$PR" >&2
  fi
  read_status
fi

OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

outcome() {
  # --wait passes a bound in seconds: a read that hangs then ends as a failed
  # read instead of holding the wait past --max-wait. Without timeout(1) (e.g.
  # stock macOS) the read stays unbounded.
  local bound=()
  if [ -n "${1:-}" ] && command -v timeout >/dev/null 2>&1; then
    bound=(timeout "$1")
  fi
  # shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variables, not shell
  ${bound[@]+"${bound[@]}"} gh api graphql -f owner="$OWNER" -f name="$NAME" -F pr="$PR" -f query='
  query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      pullRequest(number:$pr){
        state isInMergeQueue autoMergeRequest{ enabledBy{ login } }
      }
    }
  }' 2>/dev/null
}

# --wait spends one budget across both waits below — for the gate to open and
# for a queue entry to merge — so --max-wait bounds the whole call. Two bounds:
# the sum of the sleeps, which a test can drive, and the wall clock, which also
# counts the time each read takes. The clock starts with the first wait, so a
# call that never waits behaves as it did before.
WAITED=0; DEADLINE=""
start_wait() { [ -n "$DEADLINE" ] || DEADLINE=$((SECONDS + WAIT_MAX)); }
# The next sleep: what is left of --max-wait and of the wall-clock deadline,
# at most --interval. Once either is used up it is 0 or less, which ends the
# wait.
next_step() {
  local step=$WAIT_INTERVAL
  [ $((WAIT_MAX - WAITED)) -lt "$step" ] && step=$((WAIT_MAX - WAITED))
  [ $((DEADLINE - SECONDS)) -lt "$step" ] && step=$((DEADLINE - SECONDS))
  printf '%s\n' "$step"
}

# The steps pr-status.sh answers while something is still on its way: checks
# running, a requested bot review not delivered yet, a queue entry, a runner
# shortage. The same list pr-sweep.sh keeps waiting on.
is_waiting() {
  case "$1" in
    wait|await-review|await-checks|await-capacity) return 0 ;;
    *) return 1 ;;
  esac
}

# wait_in_queue <label>: stay until the queue entry has merged or left the
# queue, then exit. Returning at "queued" left the wait to the caller, who
# wrote a poll of their own instead of running the waiter pr-merge.sh names,
# and that poll read a field gh pr view does not have.
#
# This polls the two facts the wait is about, state and isInMergeQueue, and
# nothing else. pr-status.sh --watch is the wrong waiter here: its NEXT ladder
# ranks rebase, fix-ci, resolve-threads and address-comments above the
# queued-entry `wait`, so it returns while the entry is still queued and may
# still merge (a reviewer's "LGTM" after enqueueing is enough). Once the entry
# has left the queue, or the wait runs out, pr-status.sh names the next step.
wait_in_queue() {
  local label="$1" last_ok=1 out_seen=0 step q f state="" inq=""
  start_wait
  while :; do
    if q=$(outcome "$WAIT_READ_MAX") && f=$(printf '%s' "$q" | jq -er '.data.repository.pullRequest
          | [ .state, (.isInMergeQueue | tostring) ] | @tsv'); then
      last_ok=1
      IFS=$'\t' read -r state inq <<EOF
$f
EOF
      if [ "$state" = "MERGED" ]; then
        printf 'pr-merge: %s#%s merged (%s)\n' "$REPO" "$PR" "$label"
        exit 0
      fi
      if [ "$inq" != "true" ]; then
        # GitHub can put a dropped entry back by itself while auto-merge is
        # still armed (references/merge-gate-watcher.md), and re-queueing by
        # hand would cancel that run. So a read outside the queue counts only
        # once the next read confirms it.
        out_seen=$((out_seen + 1))
        if [ "$out_seen" -ge 2 ]; then
          printf 'pr-merge: %s#%s left the merge queue without merging (state=%s); next step:\n' \
            "$REPO" "$PR" "$state" >&2
          "$SCRIPT_DIR/pr-status.sh" -R "$REPO" "$PR" >&2
          exit 1
        fi
      else
        out_seen=0
      fi
    else
      # One failed read is not an outcome; the next poll may succeed.
      last_ok=0
    fi
    step=$(next_step)
    [ "$step" -ge 1 ] || break
    sleep "$step"
    WAITED=$((WAITED + step))
  done
  if [ "$last_ok" = "0" ]; then
    printf 'pr-merge: %s#%s: the wait ran out and the last read of the pull request failed; check it before reporting anything:\n    gh pr view %s --repo %s --json state,mergedAt\n' \
      "$REPO" "$PR" "$PR" "$REPO" >&2
    exit 2
  fi
  if [ "$out_seen" -ge 1 ]; then
    printf 'pr-merge: %s#%s was outside the merge queue at the last read (state=%s) when the wait ran out; gate:\n' \
      "$REPO" "$PR" "$state" >&2
  else
    printf 'pr-merge: %s#%s is still in the merge queue after %ss; gate:\n' "$REPO" "$PR" "$WAIT_MAX" >&2
  fi
  "$SCRIPT_DIR/pr-status.sh" -R "$REPO" "$PR" >&2
  exit 1
}

# --wait on a waiting step: re-read the gate every --interval seconds until it
# answers something else. Without this, `--wait` covered only the entry this
# call itself queued, and every other waiting step — an entry queued earlier,
# a bot review in flight, a non-required check still running — returned exit
# 1 at once, so the caller wrote a poll loop of their own (#496).
#
# Only the waiting steps are waited out. merge goes on to the merge below; an
# entry that is already queued goes to wait_in_queue and is not enqueued again
# (that would restart its checks); any other step is the caller's, and ends
# the call with exit 1 as without --wait. That includes request-review: the
# Self-review attestation of --self-reviewed is posted for the head the call
# started on, and only on the first read, never minted mid-wait for a head the
# operator may not have seen.
#
# A dry run waits for nothing: it reports what the gate answers now.
#
# --request-coderabbit adds one more step to wait on: any request-review with
# no review on the head while CodeRabbit refused THIS head as rate limited.
# That is not proof that CodeRabbit's is the only review missing (a Copilot
# demand reads the same); the request costs one comment and opens no gate.
# CodeRabbit does not resume a refused head by itself, so without a new
# `@coderabbitai review` the wait could only run out (measured on
# netresearch/terraform-provider-ad#66: 90 minutes of "Review rate limited").
# The call waits for the reset the notice names plus CR_MARGIN, reading the
# gate every max(--interval, 120 s) on the way, so a merge, a push, a closed PR
# or new comments are acted on as --wait does. At the target it posts the
# request once (cr_request); while CodeRabbit then reviews, pr-status.sh reads
# the head as in-progress and the wait holds. When CodeRabbit refuses the
# request again without moving the reset, the call ends (exit 1): posting again
# at the same reset would only be refused again.
GATE_WAITED=0
CR_STATE=""; CR_RETRY_AT=""; CR_TARGET=""; CR_HEAD=""
CR_POSTED=""; CR_DRAFT_SAID=""; CR_WAIT_SAID=""; CR_LAG_SAID=""
CR_OPEN=0; CR_ANSWERED=0

# cr_read: what the last gate read says about CodeRabbit, for
# --request-coderabbit only. CR_STATE is
#   retry    request-review, no review on the head, CodeRabbit refused this
#            head as rate limited and the reset is known: post after CR_TARGET
#   hold     the same as retry while a check is still running: wait every
#            --interval, post nothing yet
#   inflight request-review, no review on the head, CodeRabbit is reviewing it
#   draft    a draft whose head CodeRabbit refused: never posted, reported
#   ""       anything else; the flag changes nothing
# Placeholders instead of empty fields: a tab is IFS whitespace, so an empty
# field would collapse and shift the ones after it.
cr_read() {
  local f verdict reviewed draft epoch nfail npending nbusy
  CR_STATE=""; CR_RETRY_AT=""; CR_TARGET=""; CR_HEAD=""
  [ "$REQUEST_CR" = "1" ] || return 0
  f=$(printf '%s' "$STATUS" | jq -er '
    [ (.coderabbit_on_head // "none"),
      ((.has_review_on_head // false) | tostring),
      ((.draft // false) | tostring),
      (.headOid // "-"),
      (.coderabbit_retry_at // "-"),
      ((.coderabbit_retry_at // "") as $r
       | if $r == "" then "-" else (try ($r | fromdateiso8601 | tostring) catch "-") end),
      ((.checks.failing // []) | length | tostring),
      ((.checks.pending // 0) | tostring),
      ((.checks.not_started_busy_runs // []) | length | tostring)
    ] | @tsv') || return 0
  IFS=$'\t' read -r verdict reviewed draft CR_HEAD CR_RETRY_AT epoch nfail npending nbusy <<EOF
$f
EOF
  if [ "$verdict" = "rate-limited" ] && [ "$draft" = "true" ]; then
    CR_STATE=draft
    return 0
  fi
  [ "$ACTION" = "request-review" ] && [ "$reviewed" = "false" ] || return 0
  case "$verdict" in
    in-progress) CR_STATE=inflight ;;
    # The ladder answers request-review while checks still run, so the
    # request waits for them: on a red check the head needs a push, and a
    # review of it would spend the hourly allowance on a head about to go.
    # Only a check that is actually running holds, as in the ladder's draft
    # branch: with no checks at all, or a required context that never
    # reports, checks_settled stays false for good and would hold for ever.
    rate-limited)
      [[ "$epoch" =~ ^[0-9]+$ ]] && [ "$nfail" = "0" ] || return 0
      if [ "$npending" != "0" ] || [ "$nbusy" != "0" ]; then
        CR_STATE=hold
      else
        CR_STATE=retry; CR_TARGET=$((epoch + CR_MARGIN))
      fi ;;
    *) ;;
  esac
}

# Said once per call: CodeRabbit answers a draft with "Draft PR not reviewed",
# so a request there spends the hourly allowance on nothing.
cr_draft_note() {
  [ "$CR_STATE" = "draft" ] && [ -z "$CR_DRAFT_SAID" ] || return 0
  CR_DRAFT_SAID=1
  printf 'pr-merge: --request-coderabbit: %s#%s is a draft, and CodeRabbit does not review drafts — no @coderabbitai review posted. Mark it ready (gh pr ready %s --repo %s) and run this again.\n' \
    "$REPO" "$PR" "$PR" "$REPO" >&2
}

gate_waitable() {
  is_waiting "$ACTION" && return 0
  case "$CR_STATE" in retry|hold|inflight) return 0 ;; *) return 1 ;; esac
}

# cr_comments [soft]: one REST read of the PR comments, for the refusal of
# CR_HEAD that names CR_RETRY_AT. Sets CR_OPEN and CR_ANSWERED: the requests by
# anyone but CodeRabbit created at or after the reset, split by whether a
# CodeRabbit bot comment written or edited after the request says "rate
# limited" (case-insensitive). Such a comment is the refusal of that request;
# any other later CodeRabbit write ("Review triggered.", "Review finished.", a
# chat reply) means it was not refused, and the request stays open.
# pr-status.sh reads a request as in-progress until any CodeRabbit write after
# it, while this read closes it only on a "rate limited" one; the reset filter
# matters only when the two reads disagree (a lagging read): it keeps a request made into the limit, before the reset,
# from counting. A failed read ends the call (exit 2) and is not retried;
# with "soft" it returns 1 instead and sets nothing.
cr_comments() {
  local soft="${1:-}" err comments counts why
  err=$(mktemp)
  if ! comments=$(gh api "repos/$REPO/issues/$PR/comments?per_page=100" --paginate \
        --jq '.[] | {u: .user.login, t: .user.type, c: .created_at, e: .updated_at, b: .body}' 2>"$err") \
     || ! counts=$(printf '%s' "$comments" | jq -rs --arg reset "$CR_RETRY_AT" '
          ([.[] | select((.u // "") | test("^coderabbitai"; "i"))
                | select(.t == "Bot")
                | select((.b // "") | test("rate limited"; "i"))
                | (.e // .c // "")]) as $refusals
          | [.[] | select((.u // "") | test("^coderabbitai"; "i") | not)
                 | select((.b // "") | test("@coderabbitai (full )?review"))
                 | select((.c // "") >= $reset)
                 | (.c // "") as $asked
                 | ([$refusals[] | select(. > $asked)] | length == 0)]
          | "\(map(select(.)) | length) \(map(select(. | not)) | length)"' 2>>"$err") \
     || ! [[ "$counts" =~ ^[0-9]+\ [0-9]+$ ]]; then
    why=$(tr '\n' ' ' < "$err"); rm -f "$err"
    if [ "$soft" = "soft" ]; then
      printf 'pr-merge: could not read the comments of %s#%s, so whether CodeRabbit refused the request is unknown; reading again at the next step: %s\n' \
        "$REPO" "$PR" "${why:-unexpected answer}" >&2
      return 1
    fi
    die "--request-coderabbit: could not read the comments of $REPO#$PR, so whether a review request is already on its way is unknown; nothing posted: ${why:-unexpected answer}"
  fi
  rm -f "$err"
  CR_OPEN=${counts% *}; CR_ANSWERED=${counts#* }
}

cr_refused_again() {
  printf 'pr-merge: not merging %s#%s — CodeRabbit refused the @coderabbitai review request for %s again, and the reset its notice names (%s) has not moved; read its reply on the PR before requesting again\n' \
    "$REPO" "$PR" "${CR_HEAD:0:12}" "$CR_RETRY_AT" >&2
  exit 1
}

# cr_request: post `@coderabbitai review` once for the refusal of CR_HEAD that
# names CR_RETRY_AT. The gate read can lag a comment by a poll, and a restarted
# call knows nothing of an earlier one, so cr_comments reads first: an open
# request means one is on its way (no post, keep waiting); a refused one
# with no open one means CodeRabbit refused it at this same reset, the
# restarted form of cr_refused_again. A failed post ends the call (exit 2) and
# is not retried.
cr_request() {
  local key="$CR_HEAD $CR_RETRY_AT" err why
  [ "$key" != "$CR_POSTED" ] || return 0
  cr_comments
  CR_POSTED=$key
  if [ "$CR_OPEN" -gt 0 ]; then
    printf 'pr-merge: %s#%s already carries an @coderabbitai review request made after the reset %s that CodeRabbit has not refused — not posting another\n' \
      "$REPO" "$PR" "$CR_RETRY_AT" >&2
    return 0
  fi
  [ "$CR_ANSWERED" -eq 0 ] || cr_refused_again
  # The comment read takes time of its own: a request posted after --max-wait
  # ran out would go unwatched, so the budget is checked again here.
  local left=$((WAIT_MAX - WAITED))
  [ $((DEADLINE - SECONDS)) -lt "$left" ] && left=$((DEADLINE - SECONDS))
  if [ "$left" -lt 1 ]; then
    printf 'pr-merge: no @coderabbitai review posted on %s#%s — --max-wait ran out during the comment read\n' \
      "$REPO" "$PR" >&2
    return 0
  fi
  err=$(mktemp)
  if ! gh pr comment "$PR" --repo "$REPO" --body '@coderabbitai review' >/dev/null 2>"$err"; then
    why=$(tr '\n' ' ' < "$err"); rm -f "$err"
    die "--request-coderabbit: posting @coderabbitai review on $REPO#$PR failed (not retried): $why"
  fi
  rm -f "$err"
  printf 'pr-merge: posted @coderabbitai review for %s on %s#%s (the rate-limit reset was %s)\n' \
    "${CR_HEAD:0:12}" "$REPO" "$PR" "$CR_RETRY_AT" >&2
}

# The step while waiting for the reset: one gate read every max(--interval,
# 120 s), so the wait sees a merge or a push without spending a read every
# --interval on a reset that is often an hour away.
CR_STEP=$WAIT_INTERVAL
[ "$CR_STEP" -ge 120 ] || CR_STEP=120

cr_read; cr_draft_note
if [ "$WAIT" = "1" ] && [ "$DRY" != "1" ] && gate_waitable && [ "$INQUEUE" != "true" ]; then
  start_wait
  gate_ok=1; shown=""
  while :; do
    if [ "$gate_ok" = "1" ]; then
      gate_waitable && [ "$INQUEUE" != "true" ] || break
      if [ "$ACTION: $WHY" != "$shown" ]; then
        shown="$ACTION: $WHY"
        printf 'pr-merge: waiting on %s#%s — %s\n' "$REPO" "$PR" "$shown" >&2
      fi
    fi
    step=$(next_step)
    if [ "$gate_ok" = "1" ] && [ "$CR_STATE" = "retry" ] && [ "$CR_POSTED" = "$CR_HEAD $CR_RETRY_AT" ]; then
      # Requested (by this call or before it) and the gate still shows the
      # refusal at the same reset. Only a later CodeRabbit comment saying "rate
      # limited" makes that a second refusal; without one the gate read lags the
      # request, and the next step reads again (one REST read per such step).
      if cr_comments soft; then
        [ "$CR_OPEN" -eq 0 ] && [ "$CR_ANSWERED" -gt 0 ] && cr_refused_again
      fi
      if [ "$CR_LAG_SAID" != "$CR_HEAD $CR_RETRY_AT" ]; then
        CR_LAG_SAID="$CR_HEAD $CR_RETRY_AT"
        printf 'pr-merge: the gate still shows the refusal of %s, but CodeRabbit has not refused the request in a comment — reading again\n' \
          "${CR_HEAD:0:12}" >&2
      fi
    elif [ "$gate_ok" = "1" ] && [ "$CR_STATE" = "retry" ]; then
      now=$(date +%s)
      left=$((WAIT_MAX - WAITED))
      [ $((DEADLINE - SECONDS)) -lt "$left" ] && left=$((DEADLINE - SECONDS))
      if [ "$now" -ge "$CR_TARGET" ]; then
        # Posted only while time is left to watch the review it asks for.
        [ "$step" -ge 1 ] || break
        cr_request
        step=$(next_step)
      elif [ $((CR_TARGET - now)) -ge "$left" ]; then
        if [ "$CR_WAIT_SAID" != "$CR_HEAD $CR_RETRY_AT" ]; then
          CR_WAIT_SAID="$CR_HEAD $CR_RETRY_AT"
          printf 'pr-merge: CodeRabbit refused %s as rate limited until %s plus %ss, past what is left of --max-wait (%ss); no request will be posted in this call — waiting for other events only\n' \
            "${CR_HEAD:0:12}" "$CR_RETRY_AT" "$CR_MARGIN" "$left" >&2
        fi
      else
        step=$CR_STEP
        [ $((CR_TARGET - now)) -lt "$step" ] && step=$((CR_TARGET - now))
        [ "$left" -lt "$step" ] && step=$left
        if [ "$CR_WAIT_SAID" != "$CR_HEAD $CR_RETRY_AT" ]; then
          CR_WAIT_SAID="$CR_HEAD $CR_RETRY_AT"
          printf 'pr-merge: CodeRabbit refused %s as rate limited; waiting until %s plus %ss (reading the gate every %ss), then posting @coderabbitai review\n' \
            "${CR_HEAD:0:12}" "$CR_RETRY_AT" "$CR_MARGIN" "$CR_STEP" >&2
        fi
      fi
    fi
    [ "$step" -ge 1 ] || break
    sleep "$step"
    WAITED=$((WAITED + step))
    GATE_WAITED=1
    if read_status soft; then gate_ok=1; cr_read; cr_draft_note; else gate_ok=0; fi
  done
  if [ "$gate_ok" = "0" ]; then
    printf 'pr-merge: %s#%s: the wait ran out and the last read of the gate failed; read it before reporting anything:\n    pr-status.sh -R %s %s\n' \
      "$REPO" "$PR" "$REPO" "$PR" >&2
    exit 2
  fi
  if gate_waitable && [ "$INQUEUE" != "true" ]; then
    printf 'pr-merge: not merging %s#%s — still %s: %s after %ss\n' "$REPO" "$PR" "$ACTION" "$WHY" "$WAIT_MAX" >&2
    exit 1
  fi
fi

if [ "$ACTION" != "merge" ]; then
  if [ "$WAIT" = "1" ] && [ "$DRY" != "1" ] && [ "$INQUEUE" = "true" ] && is_waiting "$ACTION"; then
    printf 'pr-merge: %s#%s is already in the merge queue — waiting for it, not enqueueing again: %s\n' \
      "$REPO" "$PR" "$WHY" >&2
    wait_in_queue "through the merge queue"
  fi
  # Merged by someone else, or by auto-merge, while this call waited for the
  # gate: the outcome the caller waited for, not a refusal.
  if [ "$GATE_WAITED" = "1" ] && [ "$PRSTATE" = "MERGED" ]; then
    printf 'pr-merge: %s#%s merged while waiting for the gate (not by this call)\n' "$REPO" "$PR"
    exit 0
  fi
  printf 'pr-merge: not merging %s#%s — %s: %s\n' "$REPO" "$PR" "$ACTION" "$WHY" >&2
  exit 1
fi

# pr-status reports the method it picked; fall back to the allowed list. Squash
# is excluded on purpose even when it is the only method the repo offers — in
# that case pr-status already answers `blocked` and we never get here.
METHOD=$(printf '%s' "$STATUS" | jq -r '.next.method // ""')
if [ -z "$METHOD" ]; then
  case ",$METHODS," in
    *,merge,*)  METHOD="--merge" ;;
    *,rebase,*) METHOD="--rebase" ;;
    *) die "repo allows only [$METHODS] — enable merge or rebase, squash is not used" ;;
  esac
fi

# A merge queue rejects --delete-branch outright; whether the branch is deleted
# after a queued merge depends on delete_branch_on_merge (read below). On a pull
# request from a FORK the head branch is not ours to delete: `gh` happily deletes it when the token carries push rights
# through maintainerCanModify, and the contributor loses the branch their work
# is on — the one case where the flag destroys somebody else's state rather
# than tidying our own.
# Third case: the head branch is the BASE of another open pull request. Deleting
# it CLOSES that pull request — and a closed pull request's base cannot be
# retargeted, so recovery is pushing the branch back, reopening, retargeting and
# deleting again, in that order. (GitHub documents retargeting dependent pull
# requests when a merged head branch is deleted; on
# netresearch/ldap-selfservice-password-changer#685 it closed instead, so the
# branch is kept rather than the documented behaviour trusted.)
#
# An empty answer from a FAILED query would look exactly like "nothing is
# stacked", so the query's exit status decides, and a failure keeps the branch.
STACKED=""
STACKED_UNKNOWN=""
TMPERR=$(mktemp)
trap 'rm -f "$TMPERR"' EXIT
# The query also runs for a merge queue. The queue never takes --delete-branch,
# but whether delete_branch_on_merge (below) deletes the branch after a queued
# merge is not documented, so the queue is treated like a direct merge: a
# refusal that was not needed costs a retarget, a merge that closes the
# children cannot be undone.
if [ "$CROSS" != "true" ]; then
  if [ -z "$HEADREF" ]; then
    # Nothing to ask about: an older pr-status.sh that does not report the head
    # branch leaves the same doubt a failed query does, and is answered the
    # same way.
    STACKED_UNKNOWN="pr-status.sh reported no head branch"
  # --limit: gh pr list stops at 30 by default, and a child past the limit
  # would be neither retargeted nor named.
  elif ! STACKED=$(gh pr list --repo "$REPO" --base "$HEADREF" --state open --limit 1000 \
      --json number --jq '[.[].number | "#" + tostring] | join(" ")' 2>"$TMPERR"); then
    STACKED=""
    STACKED_UNKNOWN=$(tr '\n' ' ' < "$TMPERR")
    [ -n "$STACKED_UNKNOWN" ] || STACKED_UNKNOWN="gh pr list failed"
  fi
fi

# Withholding --delete-branch keeps nothing when the repository deletes merged
# head branches itself: with delete_branch_on_merge on, GitHub deletes the
# branch whatever the flag says, and every open pull request based on it is
# closed (#460). So when anything is, or may be, stacked on this branch, the
# setting decides. A failed read of the setting is not "off".
RETARGET_CMDS=()
if [ -n "$STACKED" ] || [ -n "$STACKED_UNKNOWN" ]; then
  # GraphQL, not REST: repos/<o>/<r> leaves delete_branch_on_merge out for a
  # caller without admin rights, while deleteBranchOnMerge answers at read
  # permission.
  # shellcheck disable=SC2016  # $owner/$name are GraphQL variables, not shell
  AUTODEL=$(gh api graphql -f owner="${REPO%%/*}" -f name="${REPO##*/}" -f query='
    query($owner:String!,$name:String!){ repository(owner:$owner,name:$name){ deleteBranchOnMerge } }' \
    --jq '.data.repository.deleteBranchOnMerge' 2>"$TMPERR") \
    || die "could not read delete_branch_on_merge of $REPO, so whether merging deletes $HEADREF is unknown: $(tr '\n' ' ' < "$TMPERR")"
  # Only a literal answer counts: `null` or an empty line is not "off".
  case "$AUTODEL" in
    true|false) ;;
    *) die "delete_branch_on_merge of $REPO read as '${AUTODEL}', neither true nor false, so whether merging deletes $HEADREF is unknown" ;;
  esac
  # A deletion rule (rulesets) or classic protection with allow_deletions off
  # keeps the branch from being deleted automatically: then its children need
  # nothing (develop -> main in git-flow). "protected" alone is not that: a
  # ruleset that only requires checks also makes a branch protected.
  # rules/branches answers at read permission; classic protection only to an
  # admin, so for a protected head whose classic protection cannot be read the
  # outcome is unknown, and nothing is merged or retargeted on a guess.
  HEADKEPT=""
  if [ "$AUTODEL" = "true" ] && [ -n "$HEADREF" ]; then
    HEADENC=$(printf '%s' "$HEADREF" | jq -sRr @uri)
    DELRULE=$(gh api "repos/$REPO/rules/branches/$HEADENC" --paginate \
        --jq '[.[] | select(.type == "deletion")] | length' 2>"$TMPERR") \
      || die "could not read the rules of $HEADREF, so whether merging deletes it is unknown: $(tr '\n' ' ' < "$TMPERR")"
    if [ "$(printf '%s\n' "$DELRULE" | awk '{s += $1} END {print s + 0}')" -gt 0 ]; then
      HEADKEPT="a deletion rule"
    else
      HEADPROT=$(gh api "repos/$REPO/branches/$HEADENC" --jq .protected 2>"$TMPERR") \
        || die "could not read whether $HEADREF is protected, so whether merging deletes it is unknown: $(tr '\n' ' ' < "$TMPERR")"
      if [ "$HEADPROT" = "true" ]; then
        if ALLOWDEL=$(gh api "repos/$REPO/branches/$HEADENC/protection" --jq '.allow_deletions.enabled' 2>"$TMPERR"); then
          case "$ALLOWDEL" in
            false) HEADKEPT="classic branch protection" ;;
            true) ;;
            *) die "the classic protection of $HEADREF read allow_deletions as '${ALLOWDEL}'" ;;
          esac
        elif grep -q 'Branch not protected' "$TMPERR"; then
          # Protected by a ruleset only, and no deletion rule (read above):
          # nothing keeps the branch.
          :
        else
          if [ -n "$STACKED_UNKNOWN" ]; then
            die "not merging: $HEADREF is protected, whether its protection forbids deletion could not be read (classic protection needs admin rights), and the pull requests based on it could not be listed: $STACKED_UNKNOWN"
          fi
          die "not merging: $HEADREF is protected, and whether its protection forbids deletion could not be read (classic protection needs admin rights). If it does, merge by hand; if not, retarget $STACKED to $BASEREF first."
        fi
      elif [ "$HEADPROT" != "false" ]; then
        die "the protection of $HEADREF read as '${HEADPROT}', neither true nor false"
      fi
    fi
    [ -n "$HEADKEPT" ] && AUTODEL=kept
  fi
  if [ "$AUTODEL" = "true" ]; then
    if [ -n "$STACKED_UNKNOWN" ]; then
      die "not merging: $REPO deletes merged head branches (delete_branch_on_merge: true), and whether open pull requests are based on ${HEADREF:-(unknown)} could not be checked: $STACKED_UNKNOWN"
    fi
    [ -n "$BASEREF" ] || die "pr-status.sh reported no base branch, so the stacked pull requests ($STACKED) have no retarget target"
    for child in $STACKED; do
      RETARGET_CMDS+=("${child#\#}")
    done
    if [ "$RETARGET" != "1" ]; then
      {
        printf 'pr-merge: not merging %s#%s — %s deletes merged head branches (delete_branch_on_merge: true),\n' "$REPO" "$PR" "$REPO"
        printf '  which would close the open pull requests based on %s: %s.\n' "$HEADREF" "$STACKED"
        printf '  Retarget them first:\n'
        # %q: the base branch name is remote data, and this line is meant to
        # be pasted into a shell.
        for child in "${RETARGET_CMDS[@]}"; do
          printf '    '; printf '%q ' gh pr edit "$child" --repo "$REPO" --base "$BASEREF"; printf '\n'
        done
        printf '  or run this script again with --retarget-stacked, which does that before merging.\n'
      } >&2
      # 2, not 1: waiting does not open this gate, so a sweep that retries
      # exit 1 on its next pass would wait out its whole timeout in silence.
      exit 2
    fi
  fi
fi

if [ "${#RETARGET_CMDS[@]}" -gt 0 ]; then
  for child in "${RETARGET_CMDS[@]}"; do
    if [ "$DRY" = "1" ]; then
      printf '%q ' gh pr edit "$child" --repo "$REPO" --base "$BASEREF"; printf '\n'
      continue
    fi
    gh pr edit "$child" --repo "$REPO" --base "$BASEREF" >/dev/null 2>"$TMPERR" \
      || die "retargeting #$child to $BASEREF failed, nothing merged: $(tr '\n' ' ' < "$TMPERR")"
    # Read the base back: a retarget that did not land leaves the child on the
    # branch the merge is about to delete.
    NOW=$(gh pr view "$child" --repo "$REPO" --json baseRefName --jq .baseRefName 2>/dev/null) || NOW=""
    [ "$NOW" = "$BASEREF" ] \
      || die "#$child still reports base '${NOW:-unreadable}' after the retarget to $BASEREF, nothing merged"
    printf 'pr-merge: retargeted %s#%s to %s\n' "$REPO" "$child" "$BASEREF" >&2
  done
fi

CMD=(gh pr merge "$PR" --repo "$REPO" "$METHOD")
if [ "$QUEUE" != "true" ] && [ "$CROSS" != "true" ] && [ -z "$STACKED" ] && [ -z "$STACKED_UNKNOWN" ]; then
  CMD+=(--delete-branch)
fi

if [ "${#RETARGET_CMDS[@]}" -gt 0 ]; then
  # The children were retargeted above, and the repository deletes the branch.
  if [ "$DRY" = "1" ]; then
    printf 'pr-merge: dry-run — %s deletes %s on merge (delete_branch_on_merge); the commands above would retarget its dependent pull requests to %s\n' \
      "$REPO" "$HEADREF" "$BASEREF" >&2
  else
    printf 'pr-merge: %s deletes %s on merge (delete_branch_on_merge); its dependent pull requests now target %s\n' \
      "$REPO" "$HEADREF" "$BASEREF" >&2
  fi
elif [ -n "$STACKED" ] && [ "$AUTODEL" = "kept" ]; then
  printf 'pr-merge: keeping branch %s — %s keeps it from being deleted, so the pull requests based on it (%s) need nothing\n' \
    "$HEADREF" "$HEADKEPT" "$STACKED" >&2
elif [ -n "$STACKED" ]; then
  printf 'pr-merge: keeping branch %s — open pull requests are based on it: %s. Retarget them, then delete it.\n' \
    "$HEADREF" "$STACKED" >&2
elif [ -n "$STACKED_UNKNOWN" ]; then
  printf 'pr-merge: keeping branch %s — could not check for dependent pull requests: %s\n' \
    "${HEADREF:-(unknown)}" "$STACKED_UNKNOWN" >&2
fi

if [ "$DRY" = "1" ]; then
  printf '%q ' "${CMD[@]}"; printf '\n'
  exit 0
fi

OUT=$("${CMD[@]}" 2>&1); RC=$?
if [ "$RC" -ne 0 ]; then
  printf 'pr-merge: %s#%s failed: %s\n' "$REPO" "$PR" "$(printf '%s' "$OUT" | tr '\n' ' ')" >&2
  exit 2
fi

# Exiting 0 is not proof that anything happened. On a repository with a merge
# queue, `gh pr merge --merge` prints its usual success line and adds NOTHING to
# the queue when an auto-merge request is already attached to the PR: the
# pending request swallows the enqueue. Observed twice on one repository —
# immediately after the call `isInMergeQueue` was false and the queue was empty;
# after `gh pr merge <n> --disable-auto` the identical call put the PR at
# position 1. Relaying the exit status as "queued" asserted a state that did not
# exist and cost hours of misdiagnosis, so the outcome is read back before it is
# claimed. This script reports; clearing the auto-merge request is the caller's
# decision, not a side effect of asking to merge.
#
# A queue entry is registered asynchronously, so the first read can legitimately
# answer false for an entry that lands a second later. The poll is bounded: a PR
# that has not appeared by then does not appear on its own, and a longer wait
# would be paid by every successful merge too.
STATE=""; INQ=""; AUTOBY="-"; PROBED=0; ATTEMPT=0
while :; do
  ATTEMPT=$((ATTEMPT + 1))
  if Q=$(outcome) && F=$(printf '%s' "$Q" | jq -er '.data.repository.pullRequest
        | [ .state, (.isInMergeQueue | tostring),
            (.autoMergeRequest.enabledBy.login // "-") ] | @tsv'); then
    IFS=$'\t' read -r STATE INQ AUTOBY <<EOF
$F
EOF
    PROBED=1
    [ "$STATE" = "MERGED" ] && break
    # Keyed on what the PR reports, not on the repo-level QUEUE flag: an entry
    # that exists is an entry, whatever the configuration said a moment ago.
    [ "$INQ" = "true" ] && break
  fi
  [ "$ATTEMPT" -ge 5 ] && break
  sleep 2
done

if [ "$STATE" = "MERGED" ]; then
  printf 'pr-merge: %s#%s merged (%s)\n' "$REPO" "$PR" "$METHOD"
  exit 0
fi
if [ "$INQ" = "true" ]; then
  printf 'pr-merge: %s#%s queued (%s, strategy set by the queue)\n' "$REPO" "$PR" "$METHOD"
  if [ "$WAIT" = "1" ]; then
    wait_in_queue "$METHOD, through the merge queue"
  fi
  # Name the waiter at the moment it is needed. Without it the next step was a
  # hand-written poll on `gh pr view --json isInMergeQueue` -- a field that
  # exists only in GraphQL, so every poll failed with `Unknown JSON field`.
  # pr-status.sh --watch holds on a queued entry (`wait`) and returns once the
  # PR is merged (`none`) or has dropped out (the next actionable step).
  printf '  wait with: %q -R %q %q --watch   (returns when merged or dropped from the queue)\n' \
    "$SCRIPT_DIR/pr-status.sh" "$REPO" "$PR"
  exit 0
fi

# Nothing landed. A probe that failed is kept apart from a probe that succeeded
# and saw nothing: an unreachable API says something about the request, not
# about the PR, and folding the two together would put a transport failure on
# the record as a fact about GitHub state. Both exit 2 — what this block exists
# for is to stop reporting an outcome that was never confirmed.
if [ "$PROBED" = "0" ]; then
  {
    printf 'pr-merge: %s#%s: the merge call exited 0 but the outcome could not be\n' "$REPO" "$PR"
    printf '  read back — %d GraphQL attempt(s) failed. Whether it merged or was\n' "$ATTEMPT"
    printf '  enqueued is unknown; establish that before reporting anything:\n'
    printf '    gh pr view %s --repo %s --json state,mergedAt\n' "$PR" "$REPO"
  } >&2
  exit 2
fi

if [ "$QUEUE" = "true" ]; then
  OBSERVED="not in the merge queue (state=$STATE, isInMergeQueue=$INQ)"
else
  OBSERVED="not merged (state=$STATE)"
fi
{
  printf 'pr-merge: %s#%s failed: gh pr merge %s exited 0 but the PR is %s\n' \
    "$REPO" "$PR" "$METHOD" "$OBSERVED"
  if [ "$AUTOBY" != "-" ]; then
    printf '  An auto-merge request enabled by %s is attached to this PR. A pending\n' "$AUTOBY"
    printf '  auto-merge request swallows the enqueue: the call succeeds, the queue\n'
    printf '  stays empty, and neither gh pr checks nor mergeStateStatus shows it.\n'
    printf '  Clear it, then run this script again:\n'
    printf '    gh pr merge %s --repo %s --disable-auto\n' "$PR" "$REPO"
  else
    printf '  No auto-merge request is attached, so the usual cause (a pending one\n'
    printf '  swallowing the enqueue) is ruled out here. Re-read the gate before\n'
    printf '  retrying:\n'
    printf '    pr-status.sh -R %s %s\n' "$REPO" "$PR"
  fi
} >&2
exit 2
