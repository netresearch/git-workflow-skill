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
# Two API calls: one GraphQL document for the PR, its checks, reviews, threads
# and the repository's merge configuration; one REST call for the effective
# branch rules (which is the only place rulesets show up).
#
# Usage:
#   pr-status.sh                      # PR for the current branch
#   pr-status.sh 123                  # PR number in the current repo
#   pr-status.sh -R owner/repo 123
#   pr-status.sh --json               # machine-readable, no prose
#   pr-status.sh --watch              # return on the FIRST actionable event
#
# --watch deliberately does not wait for every check to finish. It returns as
# soon as something can be worked on: a failing check, a new annotation, or all
# required checks concluded. Waiting for `pending == 0` means learning nothing
# until the slowest matrix job ends, long after the first failure was visible.
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
# --json contract
#
# One object, and its field names are THIS SCRIPT'S — not the GraphQL names
# `gh pr view` uses. `mergeState`, not `mergeStateStatus`. `base`, not
# `baseRefName`. Guessing costs more than reading: jq answers a missing key
# with `null` and says nothing, so a loop waiting for
# `.mergeStateStatus == "CLEAN"` never fires and reads as "still running"
# forever. Top-level keys:
#
#   state mergeable mergeState draft number title repo author
#   base head headOid
#   checks checks_settled threads unresolved_threads
#   reviewDecision reviews_on_head has_review_on_head
#   has_copilot_review_on_head copilot_review_errored copilot_error_count copilot_quota_hit
#   copilot_quota_exhausted
#   requested_reviewers
#   merge_methods auto_merge_allowed queue_active queue_entry
#   rulesets rules_fetched required_contexts undispatched unsigned
#   next
#
# `checks` is {total,pass,fail,pending,skip,...} and `next` is
# {action,why,cmd} — the same two things the prose rendering leads with.
#
# Before writing a jq filter against any of these, consider whether --watch
# already answers the question; it usually does, and a hand-rolled poll loop is
# how the wrong field name gets guessed in the first place.
#
# tests/test_pr_status_json_contract.sh fails when this list and the emitted
# object drift apart, in either direction.
set -uo pipefail

REPO=""; PR=""; JSON=0; WATCH=0; INTERVAL=20; MAXWAIT=3600

die() { printf 'pr-status: %s\n' "$1" >&2; exit 2; }

need() { [ $# -ge 2 ] && [ -n "${2:-}" ] || die "$1 requires a value"; }

while [ $# -gt 0 ]; do
  case "$1" in
    -R|--repo)  need "$@"; REPO="$2"; shift 2 ;;
    --json)     JSON=1; shift ;;
    --watch)    WATCH=1; shift ;;
    --interval) need "$@"; INTERVAL="$2"; shift 2 ;;
    --max-wait) need "$@"; MAXWAIT="$2"; shift 2 ;;
    # Prints the whole leading comment block rather than a fixed line range:
    # a hard-coded range silently truncates --help the moment the header
    # grows, which is how a documented contract stops being visible.
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    -*) die "unknown flag: $1" ;;
    *)  PR="$1"; shift ;;
  esac
done

command -v gh  >/dev/null || die "gh not found"
command -v jq  >/dev/null || die "jq not found"

if [ -z "$REPO" ]; then
  REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null) \
    || die "not in a repo; pass -R owner/repo"
fi
if [ -z "$PR" ]; then
  PR=$(gh pr view --repo "$REPO" --json number --jq .number 2>/dev/null) \
    || die "no PR for the current branch; pass a number"
fi
OWNER="${REPO%%/*}"; NAME="${REPO##*/}"

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

quota_marker_seen() { if [ -f "$QUOTA_MARKER" ]; then echo true; else echo false; fi; }

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
collect() {
  # shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variables, not shell
  gh api graphql -f owner="$OWNER" -f name="$NAME" -F pr="$PR" -f query='
  query($owner:String!,$name:String!,$pr:Int!){
    repository(owner:$owner,name:$name){
      nameWithOwner
      mergeCommitAllowed rebaseMergeAllowed squashMergeAllowed autoMergeAllowed
      pullRequest(number:$pr){
        number title state isDraft mergeable mergeStateStatus reviewDecision
        mergeQueueEntry{ state position estimatedTimeToMerge }
        author{login}
        baseRefName headRefName headRefOid isCrossRepository
        reviews(last:50){ nodes{ author{login} state commit{oid} body } }
        reviewRequests(first:20){ nodes{ requestedReviewer{
          ... on User{login} ... on Bot{login} ... on Team{slug} } } }
        reviewThreads(first:100){ nodes{ id isResolved isOutdated
          comments(first:1){ nodes{ databaseId author{login} path } } } }
        # One unsigned commit anywhere on the branch shuts a required_signatures
        # ruleset, and GitHub surfaces that only as mergeStateStatus BLOCKED —
        # no red check, nothing in the rollup. Without this the tool can only
        # say "investigate".
        allCommits: commits(first:100){ nodes{ commit{ oid signature{ isValid } } } }
        commits(last:1){ nodes{ commit{ oid statusCheckRollup{ state
          contexts(first:100){ nodes{
            __typename
            ... on CheckRun{ name conclusion status detailsUrl startedAt }
            ... on StatusContext{ context state targetUrl }
          } } } } } }
      }
    }
  }' 2>/dev/null
}

# A branch legitimately has no rules and answers `[]`, so an empty result is NOT
# an error — but a failed call must never be folded into the same value:
# "could not fetch" silently becoming "no required checks" would make this tool
# report a PR as more mergeable than it is, the one direction it must not get
# wrong. The fetch is inline rather than a function because a `$( )` subshell
# would discard the status flag.

evaluate() {
  local gql="$1" rules="$2" ok="$3" marker="$4"
  jq -n --argjson g "$gql" --argjson r "$rules" --argjson ok "$ok" \
        --argjson marker "$marker" --arg marker_path "$QUOTA_MARKER" '
    # Defined once and used by BOTH the error list and the $head_reviews filter.
    # Two hand-kept copies would have to stay byte-identical: loosening one to
    # match a third error body and not the other puts the row back into
    # $head_reviews, which is exactly the merge-on-an-unread-PR bug again.
    def is_errored_copilot_review:
      (.author.login | test("copilot"; "i"))
      and ((.body // "") | test("^Copilot\\b.*unable to review"; "i"));
    ($g.data.repository) as $repo
    | ($repo.pullRequest) as $p
    | ($p.commits.nodes[0].commit.oid) as $head
    | ([$p.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[]?
        | if .__typename == "CheckRun"
          # QUEUED and IN_PROGRESS are kept apart. Collapsing both into
          # "pending" reads as "CI is running" when in truth nothing has
          # started — and that is a different situation with a different
          # answer: a merge queue drops an entry whose required check never
          # starts, so "wait" is the wrong advice.
          # CANCELLED is kept apart from FAIL for the same reason: a run
          # superseded by the next push is cancelled, not failed, and its rows
          # stay on the commit forever. Counting them as failures reports a
          # CLEAN pull request as red and answers fix-ci for a run nobody can
          # fix. Which of the two it is depends on whether the context reported
          # again, so it is decided below and not here.
          then {name, state: (if .status == "QUEUED" then "QUEUED"
                              elif .status != "COMPLETED" then "PENDING"
                              elif .conclusion == "SUCCESS" then "PASS"
                              elif .conclusion == "SKIPPED" or .conclusion == "NEUTRAL" then "SKIP"
                              elif .conclusion == "CANCELLED" then "CANCEL"
                              else "FAIL" end), url: .detailsUrl, started: .startedAt}
          else {name: .context, state: (if .state == "SUCCESS" then "PASS"
                                        elif .state == "PENDING" then "PENDING"
                                        else "FAIL" end), url: .targetUrl}
          end]) as $checks
    # Effective required contexts come from the rules endpoint; classic
    # protection alone misses rulesets entirely.
    | ([$r[]? | select(.type=="required_status_checks")
        | .parameters.required_status_checks[]?.context]) as $required
    # Required contexts with no check-run at all. A context that never
    # reported is invisible on the PR page — the rollup only lists what ran —
    # so this reads as BLOCKED with everything green.
    | ([$required[] | select(. as $c | ($checks | map(.name) | index($c)) == null)]) as $undispatched
    | ([$r[]? | .type] | unique) as $ruletypes
    | (($ruletypes | index("copilot_code_review")) != null) as $needs_copilot
    | ($p.author.login) as $author
    # A review by the PR author is not a review. Replying to a thread registers
    # as COMMENTED by the author, which would otherwise satisfy the gate.
    | ([$p.reviews.nodes[]? | select(.commit.oid == $head)
                           | select(.author.login != $author)]) as $reviews_raw
    # A Copilot review that FAILED still arrives as an ordinary COMMENTED row.
    # Counting it as a review reports NEXT=merge for a PR nothing has read —
    # the exact gate this script exists to close. Two observed bodies:
    #   "Copilot encountered an error and was unable to review this pull request."
    #   "Copilot was unable to review this pull request because the user who
    #    requested the review has reached their quota limit."
    # Both are matched by "starts with Copilot … unable to review", which a real
    # review body does not (in jq, ^ anchors the string, not each line). The same
    # failure is ALSO a failing copilot-pull-request-reviewer check-run — but
    # that one is absent from GraphQL statusCheckRollup (it is only in the REST
    # check-runs API), so $checks cannot see it and using it would cost a third
    # API call.
    | ([$reviews_raw[] | select(is_errored_copilot_review)]) as $copilot_errored
    | (($copilot_errored | length) > 0) as $copilot_review_errored
    # Bound rather than written twice: copilot_quota_hit reports the evidence
    # found HERE, copilot_quota_exhausted folds in the marker, and a second
    # copy of the test would let the two drift into disagreeing about the same
    # review body.
    | (([$copilot_errored[] | select((.body // "") | test("quota"; "i"))] | length) > 0) as $quota_hit
    # Drop the errored rows from $head_reviews itself, not just from the Copilot
    # view: has_review_on_head feeds the generic "no review on the current head"
    # gate, so filtering only the Copilot list would leave every repo WITHOUT
    # the copilot_code_review ruleset still merging on an error row.
    | ([$reviews_raw[] | select(is_errored_copilot_review | not)]) as $head_reviews
    | ([$head_reviews[] | select(.author.login | test("copilot"; "i"))]) as $copilot_on_head
    | ([$p.reviewThreads.nodes[]? | select(.isResolved == false)]) as $unresolved
    # A cancelled context that reported again under the same name is STALE:
    # the later row is the answer and the cancelled one is a leftover. One that
    # never reported again is genuinely unmet and still shuts the gate — but it
    # needs a re-run, not a fix, so it is named separately either way.
    | ([$checks[] | select(.state=="PASS" or .state=="SKIP" or .state=="FAIL") | .name]) as $reported
    | ($checks | map(select(.state=="CANCEL" and (.name as $n | $reported | index($n)))))     as $stale
    | ($checks | map(select(.state=="CANCEL" and (.name as $n | $reported | index($n)) == null))) as $cancelled
    | (($checks | map(select(.state=="FAIL"))) + $cancelled) as $failing
    | ($checks | map(select(.state=="QUEUED"))) as $queued
    | ($checks | map(select(.state=="PENDING"))) as $running
    # "pending" downstream keeps meaning "not finished", queued or running.
    | ($queued + $running) as $pending
    | ($failing | map(select(.name as $n | $required | index($n)))) as $failing_required
    | ($pending | map(select(.name as $n | $required | index($n)))) as $pending_required
    | ($queued  | map(select(.name as $n | $required | index($n)))) as $queued_required
    # Right after a push every check is queued and none is running, which is
    # normal for a few seconds and says nothing about runner capacity. Age the
    # signal before acting on it, using the tolerance the merge queue itself
    # applies (check_response_timeout_minutes, default 5) as the threshold:
    # queued longer than the queue would wait is when it stops being fresh.
    # No apostrophes in here — the whole jq program sits in a single-quoted
    # shell string, and one would end it.
    | (($queued_required | map(.started // empty) | min) // null) as $oldest_q
    | (if $oldest_q == null then 0
       else (((now - ($oldest_q | fromdateiso8601)) / 60) | floor) end) as $queued_minutes
    | {
        repo: $repo.nameWithOwner, number: $p.number, title: $p.title,
        state: $p.state, draft: $p.isDraft,
        mergeable: $p.mergeable, mergeState: $p.mergeStateStatus,
        reviewDecision: ($p.reviewDecision // ""),
        base: $p.baseRefName, head: $p.headRefName, headOid: $head,
        checks: {
          # Stale rows are excluded so pass+fail+pending+skip still adds up to
          # total; the stale count is reported on its own line.
          total: (($checks|length) - ($stale|length)),
          pass:  ($checks|map(select(.state=="PASS"))|length),
          fail:  ($failing|length),
          pending:($pending|length),
          queued: ($queued|length),
          running:($running|length),
          skip:  ($checks|map(select(.state=="SKIP"))|length),
          stale: ($stale|length),
          # Flattened: where the name: of a workflow is an unevaluated expression the
          # check-run name arrives with newlines in it and would break the
          # single-line summary into fragments.
          cancelled: ($cancelled|map(.name|gsub("\\s+";" ")|.[0:90])),
          failing: ($failing|map(.name)),
          failing_required: ($failing_required|map(.name)),
          pending_required: ($pending_required|map(.name)),
          queued_required: ($queued_required|map(.name)),
          queued_minutes: $queued_minutes,
          failing_urls: ($failing|map(.url))
        },
        required_contexts: $required,
        rules_fetched: ($ok == 1),
        unsigned: [$p.allCommits.nodes[]?.commit
                   | select((.signature.isValid // false) | not)
                   | .oid[0:8]],
        undispatched: $undispatched,
        # Whether the check set has finished registering AND finished running.
        # The review branches of the NEXT ladder sit above every CI branch, so
        # on a repo with the copilot_code_review ruleset NEXT answers
        # request-review from the second a commit is pushed and never mentions
        # CI at all. A caller that automates enqueueing needs the CI answer on
        # its own, and the checks counts alone do not give it: right after a
        # push "0 pending" is true because one context has registered and the
        # other ninety have not.
        # null, not false, when the rules could not be fetched: $required is
        # empty then, so $undispatched is empty for the wrong reason and a
        # caller gating on this would act on a set it never verified.
        checks_settled: (if $ok == 1
                         then (($pending|length) == 0 and ($undispatched|length) == 0
                               and ($checks|length) > 0)
                         else null end),
        rulesets: $ruletypes,
        # Every distinct state per author, not just the last one. `add` over
        # map({login: state}) overwrites, so a reviewer who approves and then
        # replies to a thread displayed as COMMENTED and the approval vanished
        # from the only surface that shows it — beside decision=APPROVED, which
        # then reads as an approval on an older commit. Shape is unchanged
        # (login -> string) so consumers indexing by login still work.
        # Dedupe keeping the LAST occurrence, not unique and not keep-first.
        # unique sorts alphabetically, so APPROVED would lead even when a later
        # CHANGES_REQUESTED on the same commit superseded it; keep-first has the
        # same flaw once a state recurs (CHANGES_REQUESTED, APPROVED,
        # CHANGES_REQUESTED would end on the withdrawn APPROVED).
        # What this guarantees is exactly: each distinct state once, ordered by
        # its LAST occurrence. Not "the trailing entry is the current state" —
        # a CHANGES_REQUESTED followed by a thread reply renders
        # CHANGES_REQUESTED+COMMENTED, and the blocking state is the first one.
        # This field is for display; the decision path reads $head_reviews.
        reviews_on_head: ($head_reviews
                          | group_by(.author.login)
                          | map({(.[0].author.login):
                                 (map(.state)
                                  | reduce .[] as $st ([]; (. - [$st]) + [$st])
                                  | join("+"))})
                          | add // {}),
        has_review_on_head: (($head_reviews|length) > 0),
        has_copilot_review_on_head: (($copilot_on_head|length) > 0),
        # True when Copilot answered on this head with an error body rather than
        # a review. Derived from the review body alone — see the comment above
        # $copilot_errored for why the check-run is not consulted.
        copilot_review_errored: $copilot_review_errored,
        copilot_error_count: ($copilot_errored|length),
        # True when an errored Copilot review body ON THIS PR names the quota
        # limit — the evidence, not the verdict.
        copilot_quota_hit: $quota_hit,
        # The verdict, and what the NEXT ladder reads: the quota is MONTHLY and
        # account-wide, so it is equally exhausted on a PR that carries no
        # evidence of its own. True when this PR proves it, or when an earlier
        # invocation this calendar month wrote the marker.
        copilot_quota_exhausted: ($quota_hit or $marker),
        author: $author,
        requested_reviewers: [$p.reviewRequests.nodes[]?.requestedReviewer|(.login // .slug)],
        unresolved_threads: ($unresolved|length),
        threads: [$unresolved[]|{threadId: .id,
                                 commentId: .comments.nodes[0].databaseId,
                                 author: .comments.nodes[0].author.login,
                                 path: .comments.nodes[0].path,
                                 outdated: .isOutdated}],
        merge_methods: ([ (if $repo.mergeCommitAllowed then "merge" else empty end),
                          (if $repo.rebaseMergeAllowed then "rebase" else empty end),
                          (if $repo.squashMergeAllowed then "squash" else empty end) ]),
        auto_merge_allowed: $repo.autoMergeAllowed,
        queue_active: (($p.mergeStateStatus == "BLOCKED" or $p.mergeStateStatus == "CLEAN")
                       and ($ruletypes | index("merge_queue")) != null),
        # queue_active describes the REPO — a queue exists and this PR would go
        # through it. queue_entry describes THIS PR: non-null only while it is
        # actually sitting in the queue. Without the second one, an enqueued PR
        # still reads as CLEAN and gets answered "merge", which re-enqueues it.
        queue_entry: (if $p.mergeQueueEntry then
                        {state: $p.mergeQueueEntry.state,
                         position: $p.mergeQueueEntry.position,
                         eta: $p.mergeQueueEntry.estimatedTimeToMerge}
                      else null end)
      }
    # ---- next valid action, highest-priority first -------------------------
    | . as $s
    # Bound once: two branches below suppress the retry command on it (the
    # ruleset one and the generic one). As two hand-kept copies, raising the
    # threshold in one place only would quietly restore the unbounded
    # re-request loop in the other — the same trap `is_errored_copilot_review`
    # is factored out to avoid.
    | ($s.copilot_error_count >= 2) as $copilot_exhausted
    # Hoisted so BOTH exhausted variants can append it. The two branches below
    # serve disjoint repo populations — with the copilot_code_review ruleset
    # active, has_copilot_review_on_head implies has_review_on_head, so the
    # generic branch is unreachable there — which is why fixing one of them
    # left the other silently unwarned.
    # An APPROVED decision sits on an OLDER commit only when nothing APPROVED
    # the current head. has_review_on_head is the wrong test: it is true for any
    # non-author review including a COMMENTED one, and a thread reply registers
    # as exactly that (see the $reviews_raw comment), so one reply after the
    # last push would drop this warning while the approval is still stale.
    # Read the LIST, not reviews_on_head: that field joins the states per author
    # into one string for display, so testing it would mean substring-matching
    # "APPROVED" out of e.g. "APPROVED+CHANGES_REQUESTED" and calling a
    # superseded approval current. The list carries each review as its own row.
    | ([$head_reviews[] | select(.state == "APPROVED")] | length == 0) as $no_current_approval
    | (if ($s.reviewDecision == "APPROVED") and $no_current_approval
       then "; the existing APPROVED review sits on an older commit and this repo does not dismiss it"
       else "" end) as $stale_approval
    # One source for the phrase; the branches differ only in what follows it.
    # The copilot branch is not gated on has_review_on_head, so it must not
    # assert this when a review does exist on the head.
    | "no review on the current head (\($s.headOid[0:8])) — do not merge unreviewed" as $no_review
    | (if ($s.has_review_on_head | not) then "\($no_review). " else "" end) as $unreviewed
    # One quota sentence for every branch that would otherwise hand back a
    # re-request command. Where the evidence came from is stated rather than
    # assumed: on a PR that carries no Copilot row at all, saying the error
    # body names the limit would describe a review that is not there — and the
    # operator could not tell a fresh reading from a remembered one, nor find
    # the file to undo it.
    | (if $s.copilot_quota_hit
       then "the error body on this pull request says the requesting user reached the quota limit"
       else "an earlier run recorded the wall this month in \($marker_path) — delete that file if it was recorded in error"
       end) as $quota_evidence
    | ("Copilot is OUT OF REVIEW QUOTA — \($quota_evidence). The quota is MONTHLY and"
       + " account-wide: it will not recover this month, on this or any other PR, and"
       + " re-requesting cannot change that. Review the diff yourself, note in the PR that"
       + " the bot review was unavailable, and decide on that. Treat this notice as covering"
       + " every PR until the monthly reset") as $quota_why
    | .next =
        (if $s.state != "OPEN" then
           {action:"none", why:"PR is \($s.state)"}
         elif ($s.rules_fetched|not) then
           {action:"rules-unavailable",
            why:"could not read repos/\($s.repo)/rules/branches/\($s.base) — the required-check list is unknown, so no merge verdict is possible from here"}
         elif $s.draft then
           {action:"ready", why:"draft", cmd:"gh pr ready \($s.number) --repo \($s.repo)"}
         elif $s.mergeable == "CONFLICTING" then
           {action:"resolve-conflicts", why:"merge conflict with \($s.base)"}
         elif $s.mergeState == "BEHIND" then
           {action:"rebase", why:"branch is behind \($s.base)",
            cmd:"git fetch origin \($s.base):refs/remotes/origin/\($s.base) && git rebase origin/\($s.base) && git push --force-with-lease"}
         elif ($s.checks.failing_required|length) > 0 then
           {action:"fix-ci", why:"required check(s) failing: \($s.checks.failing_required|join(", "))",
            urls:$s.checks.failing_urls}
         elif ($s.checks.fail > 0) then
           {action:"triage-ci", why:"non-required check(s) failing: \($s.checks.failing|join(", ")) — not merge-blocking on their own, but UNSTABLE keeps the gate shut",
            urls:$s.checks.failing_urls}
         elif $s.unresolved_threads > 0 then
           {action:"resolve-threads", why:"\($s.unresolved_threads) unresolved review thread(s)",
            threads:$s.threads}
         # Sits after the branches that report real work (failing checks,
         # open threads) — those stay worth doing while queued, and a queue
         # entry that fails its own checks is dropped anyway. It sits before
         # every review and merge branch: GitHub already let this PR past the
         # rulesets when it accepted the entry, so "request a review" or
         # "merge" here is advice that would dequeue it and start over.
         elif ($s.queue_entry != null) then
           {action:"wait",
            why:("already in the merge queue at position \($s.queue_entry.position)"
                 + " (\($s.queue_entry.state))"
                 # Spelled `!= null` rather than left implicit: jq counts only
                 # null and false as false, so a 0-second ETA does render — but
                 # a reader arriving from a language where 0 is falsy reads a
                 # bug here that is not present.
                 + (if ($s.queue_entry.eta != null)
                    then ", ~\((($s.queue_entry.eta) / 60) | floor) min to go"
                    else "" end)
                 + " — the queue merges it once its own checks pass; enqueueing"
                 + " again only restarts them")}
         # A required-signatures gate can live in CLASSIC branch protection,
         # which neither the rulesets endpoint nor a non-admin protection
         # query can see: mergeState sits at BLOCKED while every visible gate
         # is green. When a branch commit is unsigned, that invisible gate is
         # the prime suspect — and it must outrank the advisory review
         # branches below, which otherwise mask it (observed: a
         # `gh pr update-branch --rebase` re-wrote the head UNSIGNED and the
         # PR reported request-review while the real blocker was the
         # signature; #187). Guarded on checks_settled and zero failures so
         # it only fires when nothing visible explains the BLOCKED.
         # reviewDecision is consulted first: BLOCKED caused by a required
         # human review (REVIEW_REQUIRED / CHANGES_REQUESTED) reaches this
         # spot too, and authors who simply do not sign commits would get a
         # history-rewriting rebase command for a review problem.
         elif (($s.unsigned|length) > 0
               and $s.mergeState == "BLOCKED"
               and ($s.reviewDecision != "REVIEW_REQUIRED")
               and ($s.reviewDecision != "CHANGES_REQUESTED")
               and $s.checks_settled
               and (($s.checks.failing|length) == 0)
               and $s.unresolved_threads == 0) then
           {action:"fix-signatures",
            why:("\($s.unsigned|length) commit(s) on this branch carry no valid signature — \($s.unsigned|join(", "))"
                 + " — and mergeState is BLOCKED with every visible gate green."
                 + " A signature requirement in classic branch protection is"
                 + " invisible to the rulesets endpoint and to non-admin"
                 + " queries — fix the signatures before chasing review state."
                 + " Note: gh pr update-branch re-writes the head UNSIGNED;"
                 + " rebase locally instead"),
            # No single quotes in here: the whole jq program lives in a
            # single-quoted shell string (same trap as the sibling cmd below).
            cmd:"git rebase --exec \"git commit --amend --no-edit -S\" $(git merge-base HEAD origin/\($s.base)) ; git push --force-with-lease"}
         # `|` binds looser than `and`, so the negation needs its own parens:
         # `a and b|not` parses as `(a and b)|not` and inverts the whole test.
         # has_copilot_review_on_head must be false too: the error row stays on
         # the head forever, so without it a successful re-review would still
         # report request-review and loop the operator.
         #
         # Repeated failures change the ADVICE, not the action. An earlier
         # version escalated to a distinct "review-yourself" action; it was
         # unreachable-to-leave, because a review by the PR author is excluded
         # from $head_reviews by design (line above) — and the operator driving
         # this script IS usually the author, so doing what the action asked
         # produced a row that was then discarded and the action re-fired
         # forever. The tool cannot observe "a human read the diff", so it no
         # longer pretends to: it keeps reporting the honest state and only
         # stops handing over a retry command a quota ceiling will reject.
         elif ($needs_copilot and $s.copilot_review_errored
               and ($s.has_copilot_review_on_head | not)
               and (($s.requested_reviewers|map(test("copilot";"i"))|any) | not)) then
           (if $s.copilot_quota_exhausted then
             # Quota, not outage: the quota limit is named — by this PR or by
             # the marker an earlier run left. Said once, with the fact that
             # makes retrying pointless: the quota is monthly and will NOT
             # recover this month, on this or any other PR. No cmd on purpose,
             # there is nothing to run.
             {action:"request-review",
              why:($unreviewed + $quota_why + $stale_approval)}
            elif $copilot_exhausted then
             {action:"request-review",
              why:($unreviewed
                   + "Copilot failed \($s.copilot_error_count)x on \($s.headOid[0:8]), so the COMMENTED rows"
                   + " carry an error in the body rather than a review. Do not keep"
                   + " re-requesting: an outage may clear, a quota ceiling does not clear by"
                   + " asking. Review the diff yourself, say in the PR that the bot review was"
                   + " unavailable, and decide on that. This stays request-review because the"
                   + " ruleset still has no bot review — the tool cannot see that you read the"
                   + " diff\($stale_approval)")}
            else
             {action:"request-review",
              why:($unreviewed
                   + "Copilot answered on \($s.headOid[0:8]) but the review FAILED — the COMMENTED"
                   + " row carries an error in its body (an outage, or the requesting account is"
                   + " out of quota), not a review. Re-request once; if it fails again, review it"
                   + " yourself rather than retrying\($stale_approval)"),
              cmd:"gh api repos/\($s.repo)/pulls/\($s.number)/requested_reviewers -X POST -f \"reviewers[]=copilot-pull-request-reviewer[bot]\""}
            end)
         elif ($needs_copilot and ($s.has_copilot_review_on_head|not)
               and ($s.requested_reviewers|map(test("copilot";"i"))|any)) then
           {action:"await-review", why:"Copilot review already requested for \($s.headOid[0:8]) and not delivered yet — waiting, not re-requesting"}
         elif ($needs_copilot and ($s.has_copilot_review_on_head|not)) then
           # This branch outranks every CI branch below, so it is the one place
           # the CI state has to be carried along: without it NEXT reads
           # request-review while the checks are still registering, and a
           # caller that acts on it enqueues a pull request whose CI has not
           # started. Says it, rather than reordering the ladder — the review
           # really is the blocking gate here.
           #
           # This is the branch a PR reaches when Copilot was never asked here
           # at all, so it carries no error row and $copilot_review_errored is
           # false. Until the marker existed, that was every PR in every OTHER
           # repo once the account hit the wall, and each of them was handed a
           # POST command the quota had already made impossible.
           (if $s.copilot_quota_exhausted then
              {action:"request-review",
               why:($unreviewed + $quota_why + $stale_approval)}
            else
              {action:"request-review", why:("copilot_code_review ruleset is active and Copilot has not reviewed \($s.headOid[0:8]) — the rule itself does not block the merge, since a Copilot review does not count toward required approvals; the demand here is the never-merge-unreviewed policy, not a host gate"
                    + (if $s.checks_settled then "" else " (CI is NOT settled yet: \($s.checks.pending) pending, \($s.undispatched|length) required context(s) not reported — do not enqueue on this reading)" end)),
               cmd:"gh api repos/\($s.repo)/pulls/\($s.number)/requested_reviewers -X POST -f \"reviewers[]=copilot-pull-request-reviewer[bot]\""}
            end)
         elif ($s.has_review_on_head|not) then
           # The generic gate is also reached by repos WITHOUT the
           # copilot_code_review ruleset, and its cmd re-requests Copilot. Once
           # Copilot has failed twice on this head, handing that command back
           # is an unbounded loop: the retry errors, no review lands, the same
           # cmd is offered again. The two-strikes suppression therefore lives
           # here as well as in the ruleset branch above — it must not be gated
           # on $needs_copilot.
           # The stale-APPROVED warning belongs on BOTH exhausted variants: render
           # prints mergeState=CLEAN and decision=APPROVED directly above this
           # line, so dropping "do not merge unreviewed" reads as license to
           # merge on a review that sits on an older commit.
           (if $s.copilot_quota_exhausted then
               # Reached without any Copilot row of its own whenever the marker
               # is what proves the wall — the generic gate serves the repos
               # without the ruleset, and its cmd re-requests the same bot.
               {action:"request-review",
                why:($unreviewed + $quota_why + $stale_approval)}
             elif $copilot_exhausted then
               {action:"request-review",
                why:("\($no_review). "
                     + "Copilot failed \($s.copilot_error_count)x on it, so its rows carry an error"
                     + " rather than a review. Do not keep re-requesting: an outage may clear, a"
                     + " quota ceiling does not clear by asking. Review the diff yourself and"
                     + " decide on that\($stale_approval)")}
              else
               {action:"request-review",
                why:($no_review + $stale_approval),
                cmd:"gh api repos/\($s.repo)/pulls/\($s.number)/requested_reviewers -X POST -f \"reviewers[]=copilot-pull-request-reviewer[bot]\""}
              end)
         # A required check that is QUEUED with nothing running is not "CI is
         # slow" — no runner has picked it up. It is reported separately
         # because the answer differs: waiting is right for a running check,
         # while a queued one that never starts gets a merge-queue entry
         # dropped, and the operator wants to know that before enqueueing.
         elif (($s.checks.queued_required|length) > 0 and $s.checks.running == 0
               and $s.checks.queued_minutes >= 5) then
           {action:"await-capacity",
            why:("required check(s) queued \($s.checks.queued_minutes) min and not started: \($s.checks.queued_required|join(", "))"
                 + " — \($s.checks.queued) queued, 0 running, so no runner has picked them up."
                 + " Enqueueing now risks the merge queue dropping the entry when its"
                 + " required check never starts")}
         elif ($s.checks.pending_required|length) > 0 then
           {action:"wait", why:"required check(s) still running: \($s.checks.pending_required|join(", "))"}
         elif ($s.mergeState == "CLEAN"
               and ($s.merge_methods|index("merge")|not)
               and ($s.merge_methods|index("rebase")|not)) then
           {action:"blocked",
            why:"clean, but this repo allows only squash — policy forbids squash, so enable merge or rebase first"}
         elif $s.mergeState == "CLEAN" then
           ({action:"merge",
             why:"clean",
             method:(if ($s.merge_methods|index("merge")) then "--merge" else "--rebase" end)}
            + (if $s.queue_active
               then {note:"merge queue active — omit --delete-branch (it is rejected) and let the queue pick the strategy"}
               else {} end))
         elif ($s.mergeState == "UNSTABLE" and $s.checks.pending > 0) then
           # GitHub reports UNSTABLE while a non-required check is merely
           # pending, not only when one is red. Calling that "a non-required
           # check is red" sends the reader hunting for a failure that does
           # not exist — nothing here has failed yet.
           {action:"wait",
            why:("UNSTABLE while \($s.checks.pending) non-required check(s) have not finished"
                 + " (\($s.checks.running) running, \($s.checks.queued) queued) — nothing has failed")}
         elif $s.mergeState == "UNSTABLE" then
           {action:"triage-ci", why:"UNSTABLE: a non-required check is red; the gate stays shut until it is green or the PR is force-merged"}
         elif $s.checks.pending > 0 then
           {action:"wait", why:"\($s.checks.pending) check(s) still running (none of them required)"}
         # Checked last, because it only matters once everything visible is
         # green: an unsigned commit produces no red check and no rollup entry,
         # so it surfaces purely as BLOCKED and used to end here as
         # "investigate".
         elif (($s.unsigned|length) > 0 and (($ruletypes | index("required_signatures")) != null)) then
           {action:"fix-signatures",
            why:("\($s.unsigned|length) commit(s) on this branch carry no valid signature — \($s.unsigned|join(", "))"
                 + " — and the required_signatures ruleset is active. GitHub reports this"
                 + " only as mergeStateStatus \($s.mergeState), never as a failing check"),
            # No single quotes in here: the whole jq program lives in a
            # single-quoted shell string and one would end it (shellcheck
            # SC2026 catches it, but only after the parse has already gone
            # wrong further down).
            cmd:"git rebase --exec \"git commit --amend --no-edit -S\" $(git merge-base HEAD origin/\($s.base)) ; git push --force-with-lease"}
         # Same shape as fix-signatures above: a required context that never
         # reported produces no red check and no rollup entry, so it used to
         # end here as "investigate". Two causes, both mechanical: the
         # workflows were never dispatched, or this is a fork PR whose runs
         # sit at action_required and need approving once per push.
         elif (($s.undispatched|length) > 0) then
           {action:"await-checks",
            why:("\($s.undispatched|length) required check(s) never reported — \($s.undispatched|join(", "))"
                 + ". Nothing is red; they were never dispatched, or this is a fork PR"
                 + " whose runs need approving (once per push)"),
            # No single quotes: this jq program lives in a single-quoted
            # shell string (same trap the fix-signatures cmd above notes).
            cmd:("gh run list --repo \($s.repo) --branch \($s.head) --json databaseId,status,name"
                 + " — then for each action_required id:"
                 + " gh api -X POST repos/\($s.repo)/actions/runs/ID/approve."
                 + " If none await approval, close+reopen the PR to re-fire the events")}
         else
           {action:"investigate", why:"mergeState=\($s.mergeState) with no failing check, no open thread and no missing review — check branch protection manually"}
         end)
  '
}

render() {
  jq -r '
    "PR #\(.number)  \(.title)",
    "  state       : \(.state)\(if .draft then " (DRAFT)" else "" end)  mergeable=\(.mergeable)  mergeState=\(.mergeState)",
    "  head        : \(.headOid[0:8]) on \(.head) -> \(.base)",
    "  checks      : \(.checks.pass) pass, \(.checks.fail) fail, \(.checks.pending) pending\(if .checks.pending > 0 then " (\(.checks.running) running, \(.checks.queued) queued)" else "" end), \(.checks.skip) skip (of \(.checks.total))",
    (if (.checks.failing|length) > 0 then "  failing     : \(.checks.failing|join(", "))" else empty end),
    (if (.checks.cancelled|length) > 0 then "  cancelled   : \(.checks.cancelled|join(", ")) — re-run, do not debug" else empty end),
    (if .checks.stale > 0 then "  stale       : \(.checks.stale) cancelled row(s) from a superseded run, ignored" else empty end),
    (if (.checks.failing_required|length) > 0 then "  ^ REQUIRED  : \(.checks.failing_required|join(", "))" else empty end),
    "  rulesets    : \(if (.rulesets|length)>0 then (.rulesets|join(", ")) else "none" end)",
    "  reviews     : \(if .has_review_on_head then (.reviews_on_head|to_entries|map("\(.key)=\(.value)")|join(", ")) else "NONE on current head" end)  decision=\(if .reviewDecision=="" then "-" else .reviewDecision end)",
    "  threads     : \(.unresolved_threads) unresolved",
    "  merge       : methods=[\(.merge_methods|join(","))] auto=\(.auto_merge_allowed) queue=\(.queue_active)",
    (if .queue_entry then
       "  in queue    : position \(.queue_entry.position), \(.queue_entry.state)\(if (.queue_entry.eta != null) then ", ~\(((.queue_entry.eta) / 60) | floor) min" else "" end)"
     else empty end),
    "",
    "NEXT: \(.next.action) — \(.next.why)",
    (if .next.method then "  method: \(.next.method)" else empty end),
    (if .next.note   then "  note  : \(.next.note)"   else empty end),
    (if .next.cmd    then "  cmd   : \(.next.cmd)"    else empty end),
    (if .next.threads then (.next.threads[]|"  thread \(.threadId) (comment \(.commentId)) by \(.author) on \(.path)") else empty end),
    (if .next.urls then (.next.urls[]|"  \(.)") else empty end)
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
  if r=$(gh api "repos/$REPO/rules/branches/$enc" 2>/dev/null); then ok=1; else ok=0; r='[]'; fi
  out=$(evaluate "$g" "$r" "$ok" "$(quota_marker_seen)")
  # Written from the EVIDENCE field, never from the verdict: with
  # copilot_quota_exhausted the marker would re-assert itself, and the PR named
  # inside it would be whichever one read the file rather than the one that
  # proved the wall — the single thing the content is there to answer.
  if [ "$(jq -r '.copilot_quota_hit // false' <<<"$out")" = "true" ]; then
    remember_quota_hit
  fi
  printf '%s\n' "$out"
}

emit() {
  if [ "$JSON" = "1" ]; then jq . <<<"$1"; else render <<<"$1"; fi
}

# ---------------------------------------------------------------- run -------
if [ "$WATCH" = "0" ]; then
  emit "$(snapshot)"
  exit 0
fi

# Watch: stop at the first thing that can be acted on, not at full settle.
start=$(date +%s); seen_fail=""
while :; do
  s=$(snapshot)
  act=$(jq -r '.next.action' <<<"$s")
  fails=$(jq -r '.checks.failing|join(",")' <<<"$s")

  if [ -n "$fails" ] && [ "$fails" != "$seen_fail" ]; then
    seen_fail="$fails"
    echo "ACTIONABLE: check failed -> $fails"
    emit "$s"; exit 0
  fi
  case "$act" in
    request-review)
      # request-review while CI has not settled is not actionable yet — the
      # ladder itself stamps "do not enqueue on this reading" onto the why.
      # Keep waiting: a failing check fires the branch above, and once the
      # checks settle this returns on the review state (#186). The quota
      # dead-end is exempt — waiting cannot clear it, return immediately.
      if [ "$(jq -r '.checks_settled' <<<"$s")" != "true" ] \
         && [ "$(jq -r '.copilot_quota_exhausted // false' <<<"$s")" != "true" ]; then
        :
      # A request-review whose cause is an exhausted review bot is a standing
      # condition, not an event: waiting cannot clear a quota ceiling, so every
      # re-arm of --watch returns instantly with the same line. Saying so is
      # what stops an operator re-arming it three times before switching to
      # `gh pr checks --watch`, which watches something that does move.
      elif [ "$(jq -r '.copilot_quota_exhausted // false' <<<"$s")" = "true" ]; then
        echo "ACTIONABLE: request-review (UNSATISFIABLE — Copilot is OUT OF REVIEW QUOTA" \
             "for the month; this will NOT change until the monthly reset, on this or any" \
             "other PR. Do not re-arm this watch and do not re-request — review the diff" \
             "yourself and decide. To watch something that moves:" \
             "gh pr checks $(jq -r '.number' <<<"$s") --repo $(jq -r '.repo' <<<"$s") --watch)"
      elif [ "$(jq -r '.copilot_error_count // 0' <<<"$s")" -ge 2 ]; then
        echo "ACTIONABLE: request-review (UNSATISFIABLE — the review bot has failed" \
             "$(jq -r '.copilot_error_count' <<<"$s")x on this head; re-arming this watch" \
             "returns immediately. Review the diff yourself, or watch the checks instead:" \
             "gh pr checks $(jq -r '.number' <<<"$s") --repo $(jq -r '.repo' <<<"$s") --watch)"
      else
        echo "ACTIONABLE: request-review"
      fi
      # Unsettled-CI hold: emit nothing, fall through to the wait line.
      if [ "$(jq -r '.checks_settled' <<<"$s")" = "true" ] \
         || [ "$(jq -r '.copilot_quota_exhausted // false' <<<"$s")" = "true" ]; then
        emit "$s"; exit 0
      fi ;;
    fix-ci|triage-ci|resolve-threads|rebase|resolve-conflicts|merge|blocked|none|fix-signatures)
      echo "ACTIONABLE: $act"
      emit "$s"; exit 0 ;;
  esac

  now=$(date +%s)
  if [ $((now - start)) -ge "$MAXWAIT" ]; then
    echo "TIMEOUT after ${MAXWAIT}s — still: $(jq -r '.next.why' <<<"$s")"
    emit "$s"; exit 1
  fi
  echo "waiting: $(jq -r '.next.why' <<<"$s")"
  sleep "$INTERVAL"
done
