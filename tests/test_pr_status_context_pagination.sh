#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# A status rollup can exceed one GraphQL page. Its tail belongs to the same
# immutable commit, and an incomplete or drifting collection is not a gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/skills/git-workflow/scripts/pr-status.sh"
STUB_DIR="$(mktemp -d)"
trap 'rm -rf "$STUB_DIR"' EXIT
export STUB_DIR
export XDG_CACHE_HOME="$STUB_DIR/cache"
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
export HEAD_SHA
fail=0
checks=0

check() {
    local label="$1" expected="$2" actual="$3"
    checks=$((checks + 1))
    if [[ "$expected" == "$actual" ]]; then echo "  ok   $label"; else
        echo "  FAIL $label: expected '$expected', got '$actual'"; fail=1
    fi
}

cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
page=false
head=""
cursor=""
for arg in "$@"; do
    case "$arg" in
        repos/*/rules/branches/*) jq '.rules' "$STUB_DIR/case.json"; exit 0 ;;
        repos/*/branches/*/protection) echo 'gh: Branch not protected (HTTP 404)' >&2; exit 1 ;;
        repos/*/commits/*/check-runs*) echo '{"check_runs":[]}'; exit 0 ;;
        repos/*/commits/*/check-suites*) echo '{"check_suites":[]}'; exit 0 ;;
        query=*StatusContextsPage*) page=true ;;
        head=*) head=${arg#head=} ;;
        cursor=*) cursor=${arg#cursor=} ;;
    esac
done
if [[ "$page" == false ]]; then
    jq '.initial' "$STUB_DIR/case.json"
    exit 0
fi
printf '%s %s\n' "$head" "${cursor:-FIRST}" >> "$STUB_DIR/pages"
[[ "$head" == "$HEAD_SHA" ]] || { echo 'wrong commit requested' >&2; exit 1; }
if [[ "$MODE" == api-error ]]; then echo 'gh: page unavailable' >&2; exit 1; fi
if [[ -z "$cursor" ]]; then jq '.probe' "$STUB_DIR/case.json"
elif [[ "$cursor" == page-1 ]]; then jq '.page2' "$STUB_DIR/case.json"
elif [[ "$cursor" == page-2 ]]; then jq '.page3' "$STUB_DIR/case.json"
else echo 'unexpected cursor' >&2; exit 1; fi
STUB
chmod +x "$STUB_DIR/gh"

build() {
    export MODE="$1"
    : > "$STUB_DIR/pages"
    jq -n --arg head "$HEAD_SHA" --arg mode "$MODE" '
      def row($i): {__typename:"CheckRun",id:("check-"+($i|tostring)),
        name:("check-"+($i|tostring)),status:"COMPLETED",conclusion:"SUCCESS",
        detailsUrl:"https://example.test/check",startedAt:"2026-10-28T00:00:00Z",
        steps:{totalCount:1},annotations:{nodes:[]},checkSuite:{status:"COMPLETED",workflowRun:null}};
      def conn($nodes;$next;$cursor;$total):
        {nodes:$nodes,totalCount:$total,pageInfo:{hasNextPage:$next,endCursor:$cursor}};
      def page($nodes;$next;$cursor;$total):
        {data:{repository:{object:{oid:$head,statusCheckRollup:{contexts:conn($nodes;$next;$cursor;$total)}}}}};
      (if $mode == "single" then 1 else 100 end) as $n
      | [range($n)|row(.)] as $first
      | (if $mode == "three-pages" or $mode == "cycle" then 201
         elif $mode == "investigate" then 136 else $n+2 end) as $total
      | {rules:[{type:"required_status_checks",parameters:{required_status_checks:[{context:"tail-required"}]}}],
         initial:{data:{viewer:{login:"author"},repository:{nameWithOwner:"o/r",
          mergeCommitAllowed:true,rebaseMergeAllowed:false,squashMergeAllowed:false,autoMergeAllowed:true,
          pullRequest:{number:1,title:"test",state:"OPEN",isDraft:false,mergeable:"MERGEABLE",
           mergeStateStatus:"CLEAN",reviewDecision:"APPROVED",author:{login:"author",__typename:"User"},
           baseRefName:"main",headRefName:"feature",headRefOid:$head,isCrossRepository:false,
           comments:{nodes:[]},reviewRequests:{nodes:[]},reviewThreads:{nodes:[]},
           reviews:{nodes:[{author:{login:"reviewer"},state:"APPROVED",commit:{oid:$head},body:""}]},
           allCommits:{nodes:[{commit:{oid:$head,signature:{isValid:true}}}]},
           commits:{nodes:[{commit:{oid:$head,committedDate:"2026-10-28T00:00:00Z",
            statusCheckRollup:{state:"SUCCESS",contexts:conn($first;true;"page-1";$total)}}}]}}}}},
         page2:page([(row(100)|.name="tail-required"),
                    {__typename:"StatusContext",id:"legacy-1",context:"legacy-tail",state:"SUCCESS",targetUrl:"u"}];false;"page-2";$total),
         page3:page([(row(200)|.name="tail-required")];false;"page-3";$total)}
      | if $mode == "single" then
          .rules=[] | .initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts
          |= conn(.nodes;false;"page-1";1)
        elif $mode == "tail-fail" then .page2.data.repository.object.statusCheckRollup.contexts.nodes[0].conclusion="FAILURE"
        elif $mode == "tail-pending" then .page2.data.repository.object.statusCheckRollup.contexts.nodes[0].status="QUEUED"
          | .page2.data.repository.object.statusCheckRollup.contexts.nodes[0].conclusion=null
        elif $mode == "legacy-fail" then .page2.data.repository.object.statusCheckRollup.contexts.nodes[1].state="FAILURE"
        elif $mode == "three-pages" or $mode == "cycle" then
          .page2=page([range(100;200)|row(.)];true;"page-2";201)
          | if $mode == "cycle" then .page3=page([row(200)];true;"page-1";201) else . end
        elif $mode == "superseded" then
          .rules=[]
          | .initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].name="shared"
          | .initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.nodes[0].conclusion="FAILURE"
          | .page2.data.repository.object.statusCheckRollup.contexts.nodes[0].name="shared"
          | .page2.data.repository.object.statusCheckRollup.contexts.nodes[0].startedAt="2026-10-28T01:00:00Z"
        elif $mode == "missing-cursor" then
          del(.initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.endCursor)
        elif $mode == "blank-cursor" then
          .initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.endCursor=""
        elif $mode == "cursor-control" then
          .initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.endCursor="page-1\n"
        elif $mode == "final-cursor-control" then
          .page2.data.repository.object.statusCheckRollup.contexts.pageInfo.endCursor="page-2\n"
        elif $mode == "missing-total" then
          del(.initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.totalCount)
        elif $mode == "initial-errors" then .initial.errors=[{message:"partial initial response"}]
        elif $mode == "head-mismatch" then .initial.data.repository.pullRequest.headRefOid="fedcba9876543210fedcba9876543210fedcba98"
        elif $mode == "investigate" then .initial.data.repository.pullRequest.mergeStateStatus="BLOCKED"
          | .page2.data.repository.object.statusCheckRollup.contexts.nodes += [range(101;135)|row(.)]
        elif $mode == "complete-100" then .rules=[]
          | .initial.data.repository.pullRequest.mergeStateStatus="BLOCKED"
          | .initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts
          |= conn(.nodes;false;"page-1";100)
        elif $mode == "stagnant" then .page2.data.repository.object.statusCheckRollup.contexts.pageInfo.endCursor="page-1"
        elif $mode == "wrong-head" then .page2.data.repository.object.oid="fedcba9876543210fedcba9876543210fedcba98"
        elif $mode == "partial-errors" then .page2.errors=[{message:"partial response"}]
        elif $mode == "bad-page" then .page2.data.repository.object.statusCheckRollup.contexts.nodes=null
        elif $mode == "missing-page-info" then del(.page2.data.repository.object.statusCheckRollup.contexts.pageInfo)
        elif $mode == "changed-total" then .page2.data.repository.object.statusCheckRollup.contexts.totalCount=103
        elif $mode == "duplicate-id" then .page2.data.repository.object.statusCheckRollup.contexts.nodes[0].id="check-0"
        elif $mode == "missing-id" then del(.page2.data.repository.object.statusCheckRollup.contexts.nodes[0].id)
        elif $mode == "short-final" then .page2.data.repository.object.statusCheckRollup.contexts.nodes|=.[0:1]
        elif $mode == "early-final" then .initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts.pageInfo.hasNextPage=false
        else . end
      | .probe={data:{repository:{object:{oid:$head,statusCheckRollup:{contexts:
          .initial.data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts}}}}}
      | if $mode == "late-count" then .probe.data.repository.object.statusCheckRollup.contexts.totalCount+=1
        elif $mode == "late-id" then .probe.data.repository.object.statusCheckRollup.contexts.nodes[0].id="replaced-after-read"
        else . end
    ' > "$STUB_DIR/case.json"
}

run() {
    rc=0
    out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --json 2>"$STUB_DIR/err") || rc=$?
}

build single; run
check 'one page retains its verdict' merge "$(jq -r '.next.action' <<<"$out")"
check 'one page makes no continuation call' 0 "$(wc -l < "$STUB_DIR/pages" | tr -d ' ')"

build tail-pass; run
check 'a required check on page two is reported' 0 "$(jq '.undispatched|length' <<<"$out")"
check 'both context types survive collection' 102 "$(jq '.checks.total' <<<"$out")"
check 'all green pages permit the ordinary merge verdict' merge "$(jq -r '.next.action' <<<"$out")"
check 'continuation and membership probe use the immutable head' "$HEAD_SHA page-1"$'\n'"$HEAD_SHA FIRST" "$(cat "$STUB_DIR/pages")"

for mode in tail-fail legacy-fail; do
    build "$mode"; run
    check "$mode is counted" 1 "$(jq '.checks.fail' <<<"$out")"
done
build tail-pending; run
check 'pending required context on page two is retained' 1 "$(jq '.checks.pending_required|length' <<<"$out")"
build three-pages; run
check 'collection continues beyond page two' 201 "$(jq '.checks.total' <<<"$out")"
check 'page three satisfies its required context' 0 "$(jq '.undispatched|length' <<<"$out")"
check 'three-page collection follows two cursors and probes membership' 3 "$(wc -l < "$STUB_DIR/pages" | tr -d ' ')"
build superseded; run
check 'per-name newest-run selection still spans all pages' 0 "$(jq '.checks.fail' <<<"$out")"
for mode in investigate complete-100; do
    build "$mode"; run
    check "$mode reaches the evidence consumer" investigate "$(jq -r '.next.action' <<<"$out")"
    check "$mode keeps completed rollup evidence complete" false "$(jq '.next.evidence.rollup_truncated' <<<"$out")"
done

for mode in api-error missing-cursor blank-cursor stagnant cycle wrong-head partial-errors bad-page \
            missing-page-info changed-total duplicate-id missing-id short-final early-final late-count late-id \
            cursor-control final-cursor-control missing-total initial-errors head-mismatch; do
    build "$mode"; run
    check "$mode is an unreadable gate" 2 "$rc"
    check "$mode emits no green JSON decision" true "$([[ -z "$out" ]] && echo true || echo false)"
done

build api-error
rc=0
out=$(PATH="$STUB_DIR:$PATH" bash "$SCRIPT" -R o/r 1 --watch --interval 1 --max-wait 1 2>"$STUB_DIR/err") || rc=$?
check 'watch does not settle an unreadable continuation' 1 "$rc"
unreadable=false
case "$out" in *UNREADABLE*|*unreadable*) unreadable=true;; *) unreadable=false;; esac
check 'watch exposes the unreadable continuation' true "$unreadable"

printf '%s checks; failure=%s\n' "$checks" "$fail"
exit "$fail"
