#!/usr/bin/env bash
# Regression test: when the NEXT ladder ends at `investigate`, pr-status.sh
# lists the evidence it can read instead of one sentence — and still names no
# cause.
#
# Why this is a test: on netresearch/t3x-nr-image-optimize#201 (head cddd6f7c)
# the script printed only "mergeState=BLOCKED with no failing check, no open
# thread and no missing review — check branch protection manually". 72 checks
# passed, 0 failed, 0 threads, decision APPROVED. The operator then guessed a
# cause and reported it as fact. What was readable and left open on that PR:
# two required_status_checks rulesets (one strict), a failed github-actions
# check suite whose only run (copilot-pull-request-reviewer) is absent from the
# GraphQL rollup, and a pull_request rule with
# require_extra_approval_for_unattributed_changes set. Case 1 is that state.
#
# Runs pr-status.sh against a stubbed `gh`, so it needs no network and no repo.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
# The Copilot quota body below would otherwise write the monthly marker into
# the real cache of whoever runs the suite.
export XDG_CACHE_HOME="$STUB_DIR/cache"

fail=0
HEAD="cddd6f7cf8cedba97886c14dfb65387c53efd2ba"

# Each REST read the investigate path makes has its own fixture; a fixture
# holding the word FAIL makes that call exit non-zero, as a 403 would.
cat > "$STUB_DIR/gh" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    repos/*/rules/branches/*)     echo rules >>"$STUB_DIR/calls"; cat "$STUB_DIR/rules.json"; exit 0 ;;
    repos/*/branches/*/protection) echo protection >>"$STUB_DIR/calls"; echo "HTTP 404" >&2; exit 1 ;;
    repos/*/compare/*)            echo "compare \$a" >>"$STUB_DIR/calls"; f="$STUB_DIR/compare.json" ;;
    repos/*/commits/*/check-runs*)   echo check-runs >>"$STUB_DIR/calls"; f="$STUB_DIR/checkruns.json" ;;
    repos/*/commits/*/check-suites*) echo check-suites >>"$STUB_DIR/calls"; f="$STUB_DIR/checksuites.json" ;;
    *) continue ;;
  esac
  if grep -q '^FAIL' "\$f"; then echo "HTTP 403" >&2; exit 1; fi
  cat "\$f"; exit 0
done
cat "$STUB_DIR/graphql.json"
STUB
chmod +x "$STUB_DIR/gh"

# $1 = mergeStateStatus
# $2 = include the failed Copilot suite outside the rollup (yes|no)
# $3 = require_extra_approval_for_unattributed_changes (true|false)
# $4 = behind_by from the compare API
# $5 = app id that reported `security / Composer Audit` on the head
build() {
    python3 - "$STUB_DIR" "$HEAD" "$@" <<'PY'
import sys, json, os
d, head, merge_state, copilot_suite, extra, behind, audit_app = sys.argv[1:8]
GHA = 15368
ruleset_a = ["ci / Code Style", "ci / Rector", "security / Composer Audit"]
ruleset_b = ["All security checks", "DCO", "ci / All CI checks"]
rules = [
    {"type": "required_status_checks", "ruleset_id": 14253254, "parameters": {
        "strict_required_status_checks_policy": False, "do_not_enforce_on_create": True,
        "required_status_checks": [{"context": c, "integration_id": GHA} for c in ruleset_a]}},
    {"type": "deletion", "ruleset_id": 14501547, "parameters": None},
    {"type": "non_fast_forward", "ruleset_id": 14501547, "parameters": None},
    {"type": "copilot_code_review", "ruleset_id": 14501547,
     "parameters": {"review_on_push": False, "review_draft_pull_requests": False}},
    {"type": "required_signatures", "ruleset_id": 20363196, "parameters": None},
    {"type": "required_status_checks", "ruleset_id": 20441891, "parameters": {
        "strict_required_status_checks_policy": True, "do_not_enforce_on_create": False,
        "required_status_checks": [{"context": c} for c in ruleset_b]}},
    {"type": "pull_request", "ruleset_id": 20547668, "parameters": {
        "required_approving_review_count": 1, "dismiss_stale_reviews_on_push": True,
        "required_reviewers": [], "require_code_owner_review": False,
        "require_last_push_approval": False, "required_review_thread_resolution": True,
        "require_extra_approval_for_unattributed_changes": extra == "true",
        "allowed_merge_methods": ["merge"]}},
]
json.dump(rules, open(os.path.join(d, "rules.json"), "w"))

names = ruleset_a + ruleset_b
rollup = [{"__typename": "CheckRun", "name": n, "conclusion": "SUCCESS",
           "status": "COMPLETED", "detailsUrl": "u", "startedAt": "2026-09-24T10:00:00Z"}
          for n in names]
runs = [{"name": n, "status": "completed", "conclusion": "success",
         "started_at": "2026-09-24T10:00:00Z", "output": {"text": "x"},
         "app": {"id": (int(audit_app) if n == "security / Composer Audit" else
                        1861 if n == "DCO" else GHA), "slug": "github-actions"},
         "check_suite": {"id": 1}} for n in names]
suites = [{"id": 1, "status": "completed", "conclusion": "success",
           "app": {"id": GHA, "slug": "github-actions"}},
          {"id": 2, "status": "queued", "conclusion": None,
           "app": {"id": 347564, "slug": "coderabbitai"}}]
if copilot_suite == "yes":
    # The dynamic "Running Copilot Code Review" run: REST lists it, the
    # GraphQL rollup does not.
    runs.append({"name": "copilot-pull-request-reviewer", "status": "completed",
                 "conclusion": "failure", "started_at": "2026-09-24T10:01:00Z",
                 "app": {"id": GHA, "slug": "github-actions"}, "check_suite": {"id": 3}})
    suites.append({"id": 3, "status": "completed", "conclusion": "failure",
                   "app": {"id": GHA, "slug": "github-actions"}})
json.dump({"total_count": len(runs), "check_runs": runs},
          open(os.path.join(d, "checkruns.json"), "w"))
json.dump({"total_count": len(suites), "check_suites": suites},
          open(os.path.join(d, "checksuites.json"), "w"))
json.dump({"status": "ahead" if behind == "0" else "diverged",
           "ahead_by": 2, "behind_by": int(behind)},
          open(os.path.join(d, "compare.json"), "w"))

reviews = [
    {"author": {"login": "github-actions"}, "state": "APPROVED",
     "commit": {"oid": head}, "body": ""},
    {"author": {"login": "coderabbitai"}, "state": "COMMENTED",
     "commit": {"oid": head}, "body": "summary"},
    {"author": {"login": "copilot-pull-request-reviewer"}, "state": "COMMENTED",
     "commit": {"oid": head},
     "body": "Copilot was unable to review this pull request because the user who "
             "requested the review has reached their quota limit."},
]
json.dump({"data": {"viewer": {"login": "someone"}, "repository": {
    "nameWithOwner": "o/r",
    "mergeCommitAllowed": True, "rebaseMergeAllowed": False, "squashMergeAllowed": False,
    "autoMergeAllowed": True,
    "pullRequest": {
        "number": 201, "title": "t", "state": "OPEN", "isDraft": False,
        "mergeable": "MERGEABLE", "mergeStateStatus": merge_state,
        "reviewDecision": "APPROVED", "mergeQueueEntry": None,
        "author": {"login": "someone", "__typename": "User"},
        "baseRefName": "main", "headRefName": "fix/phpstan-2.2.15-findings",
        "headRefOid": head, "isCrossRepository": False,
        "comments": {"nodes": []},
        "reviews": {"nodes": reviews},
        "reviewRequests": {"nodes": []},
        "reviewThreads": {"nodes": []},
        "allCommits": {"nodes": [{"commit": {"oid": head, "signature": {"isValid": True}}}]},
        "commits": {"nodes": [{"commit": {"oid": head, "statusCheckRollup": {
            "state": "SUCCESS", "contexts": {"nodes": rollup}}}}]},
    }}}}, open(os.path.join(d, "graphql.json"), "w"))
PY
    : >"$STUB_DIR/calls"
}

run_json() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 201 --json; }
run_text() { PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 201; }

check() { # label expected actual
    if [ "$3" = "$2" ]; then echo "  ok   $1"; else
        echo "  FAIL $1: expected '$2', got '$3'"; fail=1; fi
}
check_grep() { # label pattern text
    if grep -qF -- "$2" <<<"$3"; then echo "  ok   $1"; else
        echo "  FAIL $1: '$2' not found"; fail=1; fi
}

# --- case 1: the #201 state ---------------------------------------------------
echo "case 1: t3x-nr-image-optimize#201 — BLOCKED, all green, APPROVED"
build BLOCKED yes true 0 15368
out="$(run_json)"
check "next.action" "investigate" "$(jq -r .next.action <<<"$out")"
check_grep "why says the cause is not determined" "cause is NOT determined" "$(jq -r .next.why <<<"$out")"
check "evidence.cause_determined" "false" "$(jq -r .next.evidence.cause_determined <<<"$out")"
check "every effective rule listed with its ruleset" \
      "required_status_checks:14253254,deletion:14501547,non_fast_forward:14501547,copilot_code_review:14501547,required_signatures:20363196,required_status_checks:20441891,pull_request:20547668" \
      "$(jq -r '[.next.evidence.rules[] | "\(.type):\(.ruleset_id)"] | join(",")' <<<"$out")"
check "strict rule carries behind_by" "20441891:true:0" \
      "$(jq -r '.next.evidence.status_check_rules[] | select(.strict) | "\(.ruleset_id):\(.strict):\(.behind_by)"' <<<"$out")"
check "non-strict rule carries no behind_by" "null" \
      "$(jq -r '.next.evidence.status_check_rules[] | select(.ruleset_id == 14253254) | .behind_by' <<<"$out")"
check "Composer Audit: required app, reporting app, state, no flag" "15368|[15368]|success|null" \
      "$(jq -r '.next.evidence.required_contexts[] | select(.context == "security / Composer Audit")
                | "\(.required_integration_id)|\(.reported_by_apps|tojson)|\(.state)|\(.flag)"' <<<"$out")"
check "context without integration id reads any" "any" \
      "$(jq -r '.next.evidence.required_contexts[] | select(.context == "DCO") | .required_integration_id' <<<"$out")"
check "failed suite outside the rollup, named by its check-run" "3:failure:copilot-pull-request-reviewer" \
      "$(jq -r '.next.evidence.failed_suites_outside_rollup[] | "\(.suite_id):\(.conclusion):\(.outside_rollup|join(","))"' <<<"$out")"
check "pull_request rule: approvals counted on head vs required" "1/1:true" \
      "$(jq -r '.next.evidence.pull_request_rules[0] | "\(.approvals_on_head)/\(.required_approving_review_count):\(.require_extra_approval_for_unattributed_changes)"' <<<"$out")"
check "two candidates" "2" "$(jq -r '.next.evidence.candidates | length' <<<"$out")"
check_grep "unattributed-changes rule stated as not evaluable" \
      "require_extra_approval_for_unattributed_changes — rule set, not evaluable by this script" \
      "$(jq -r '.next.evidence.candidates[]' <<<"$out")"
check_grep "hidden Copilot suite is a candidate, not a cause" \
      "copilot-pull-request-reviewer — whether it gates the merge is not determined" \
      "$(jq -r '.next.evidence.candidates[]' <<<"$out")"
check "no candidate on a passing required context" "0" \
      "$(jq -r '[.next.evidence.candidates[] | select(test("Composer Audit"))] | length' <<<"$out")"
text="$(run_text)"
check_grep "text renders the evidence block" "EVIDENCE — cause NOT determined" "$text"
check_grep "text lists the hidden suite" "outside the rollup: copilot-pull-request-reviewer" "$text"
check_grep "text shows the strict rule" "ruleset 20441891 strict=true behind_by=0" "$text"

# --- case 2: nothing left to point at ----------------------------------------
echo "case 2: no candidate in the readable data"
build BLOCKED no false 0 15368
out="$(run_json)"
check "next.action" "investigate" "$(jq -r .next.action <<<"$out")"
check "no candidates (an empty list, not an absent one)" "0" \
      "$(jq -r '.next.evidence.candidates | if type == "array" then length else "absent" end' <<<"$out")"
check "no failed suite outside the rollup (read, and empty)" "0" \
      "$(jq -r '.next.evidence.failed_suites_outside_rollup | if type == "array" then length else "absent" end' <<<"$out")"
check_grep "summary says so positively" "no candidate found in the data this script reads" \
      "$(jq -r .next.evidence.summary <<<"$out")"
check_grep "text says so too" "no candidate found in the data this script reads" "$(run_text)"

# --- case 3: strict rule, branch behind base ---------------------------------
echo "case 3: strict required_status_checks and the head is behind base"
build BLOCKED no false 3 15368
out="$(run_json)"
check "behind_by read from the compare API" "3" \
      "$(jq -r '.next.evidence.status_check_rules[] | select(.strict) | .behind_by' <<<"$out")"
check_grep "behind is listed as a candidate" \
      "ruleset 20441891 requires the branch to be up to date (strict) and the head is 3 commit(s) behind main" \
      "$(jq -r '.next.evidence.candidates[]' <<<"$out")"
check_grep "compare is asked by head sha, not branch name" "compare/main...$HEAD" "$(cat "$STUB_DIR/calls")"

# --- case 4: a required context reported by the wrong app --------------------
echo "case 4: required integration_id does not match the reporting app"
build BLOCKED no false 0 99999
out="$(run_json)"
check "flagged as integration-mismatch" "integration-mismatch" \
      "$(jq -r '.next.evidence.required_contexts[] | select(.context == "security / Composer Audit") | .flag' <<<"$out")"
check_grep "mismatch is a candidate naming both apps" \
      "required context security / Composer Audit (ruleset 14253254): integration-mismatch, state reported only by another app, required app 15368, reported by 99999" \
      "$(jq -r '.next.evidence.candidates[]' <<<"$out")"

# --- case 5: a read that fails is not an empty result ------------------------
echo "case 5: the check-runs read fails"
build BLOCKED no false 0 15368
echo FAIL > "$STUB_DIR/checkruns.json"
out="$(run_json)"
check "fetched.check_runs" "false" "$(jq -r .next.evidence.fetched.check_runs <<<"$out")"
check "contexts marked unknown, not ok" "unknown" \
      "$(jq -r '[.next.evidence.required_contexts[].flag] | unique | join(",")' <<<"$out")"
check_grep "the failed read is a candidate" "the check-runs of the head could not be read" \
      "$(jq -r '.next.evidence.candidates[]' <<<"$out")"

# --- case 6: the common path pays nothing extra ------------------------------
echo "case 6: a CLEAN pull request makes none of the extra reads"
build CLEAN yes true 3 15368
out="$(run_json)"
check "next.action" "merge" "$(jq -r .next.action <<<"$out")"
check "no evidence attached" "null" "$(jq -r .next.evidence <<<"$out")"
check "no check-runs, check-suites or compare call" "0" \
      "$(grep -cE '^(check-runs|check-suites|compare)' "$STUB_DIR/calls" || true)"

exit $fail
