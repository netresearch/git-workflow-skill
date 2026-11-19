# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
#
# pr-status-gitlab.jq — the GitLab merge-request half of pr-status.sh.
#
# Input: one object {host, project, mr, approvals, discussions, project_settings,
# jobs, viewer, merge_parents} assembled from the REST API. Output: the same --json contract
# the GitHub path emits, with the fields GitLab has no counterpart for set to
# neutral values, and the same NEXT vocabulary, so pr-status.sh --watch and its
# callers need no second ladder (#331).
#
# detailed_merge_status names only the gates the project enforces. The
# pipeline, the threads and the conflict flag are read on their own, so a
# project that does not require a green pipeline still gets fix-ci for a red
# one instead of merge.

def terminal: . as $s | ["success","failed","canceled","skipped","manual"] | index($s) != null;
def running:  . as $s | ["created","pending","running","waiting_for_resource","preparing","scheduled"] | index($s) != null;

.mr as $mr
| (.jobs // []) as $jobs
| ($mr.head_pipeline // null) as $pl
# A merged results pipeline runs on a merge commit, so its sha is not the
# head; it belongs to the head when that merge commit has the head as a parent
# (merge_parents, read by pr-status.sh for a refs/merge-requests/<iid>/merge
# or /train pipeline only).
| ($pl != null and (($pl.sha // "") == $mr.sha
     or ((.merge_parents // []) | index($mr.sha) != null))) as $pl_on_head
| (if $pl_on_head then $jobs else [] end) as $hj
| ($hj | map(select(.status == "failed" and (.allow_failure | not)) | .name) | unique) as $failing
| ($hj | map(select(.status | running) | .name) | unique) as $pending
| ($hj | map(select(.status == "canceled") | .name) | unique) as $cancelled
| ([.discussions[]? | select(.individual_note | not)
     | select(any(.notes[]?; .resolvable == true and .resolved == false))]) as $open_threads
| ($mr.detailed_merge_status // "unchecked") as $dms
| (.project_settings // {}) as $ps
| ($ps.merge_method // "merge") as $method
| ({"opened":"OPEN","merged":"MERGED","closed":"CLOSED","locked":"CLOSED"}[$mr.state] // ($mr.state | ascii_upcase)) as $state
| # sha pins the merge to the head this verdict was built on: GitLab refuses it
# when a push moved the head after the read.
("glab api --hostname \(.host) -X PUT projects/\(.project | @uri)/merge_requests/\($mr.iid)/merge -f squash=false -f sha=\($mr.sha)") as $merge_cmd
| ($pl != null and (($pl.status // "") | terminal)) as $pl_done
| {
    forge: "gitlab",
    state: $state,
    mergeable: ($mr.merge_status // ""),
    mergeState: $dms,
    draft: ($mr.draft // false),
    number: $mr.iid,
    title: ($mr.title // ""),
    repo: "\(.host)/\(.project)",
    url: ($mr.web_url // ""),
    author: ($mr.author.username // ""),
    author_is_bot: ($mr.author.bot // false),
    viewer: (.viewer // ""),
    viewer_is_author: ((.viewer // "") == ($mr.author.username // "")),
    base: ($mr.target_branch // ""),
    head: ($mr.source_branch // ""),
    headOid: ($mr.sha // ""),
    cross_repository: ($mr.source_project_id != $mr.target_project_id),
    pipeline: (if $pl == null then null else {id: $pl.id, status: $pl.status, sha: $pl.sha, on_head: $pl_on_head} end),
    checks: {
      total: ($hj | length),
      pass: ($hj | map(select(.status == "success")) | length),
      fail: ($failing | length),
      pending: ($pending | length),
      running: ($hj | map(select(.status == "running")) | length),
      queued: ($hj | map(select(.status != "running" and (.status | running))) | length),
      skip: ($hj | map(select(.status == "skipped" or .status == "manual")) | length),
      failing: $failing,
      failing_required: $failing,
      failing_other: $failing,
      failing_required_other: $failing,
      pending_required: $pending,
      cancelled: $cancelled,
      stale: 0
    },
    checks_settled: ($pl == null or ($pl_on_head and $pl_done)),
    threads: ($open_threads | length),
    unresolved_threads: ($open_threads | length),
    blocking_discussions_resolved: ($mr.blocking_discussions_resolved // true),
    has_conflicts: ($mr.has_conflicts // false),
    approved_by: [(.approvals.approved_by // [])[] | .user.username],
    approvals_required: (.approvals.approvals_required // null),
    reviewDecision: "",
    has_review_on_head: (((.approvals.approved_by // []) | length) > 0),
    coderabbit_on_head: "none",
    copilot_quota_exhausted: false,
    copilot_error_count: 0,
    self_review_on_head: false,
    merge_methods: [$method],
    squash_option: ($ps.squash_option // ""),
    queue_active: false,
    queue_entry: null,
    remove_source_branch: ($mr.force_remove_source_branch // $ps.remove_source_branch_after_merge // false)
  }
| . as $s
| .next =
  ( if $s.state != "OPEN" then {action:"none", why:"merge request is \($mr.state)"}
    elif $s.draft then {action:"ready", why:"merge request is a draft",
         cmd:"glab mr update \($mr.iid) --ready --repo \($s.repo)"}
    elif $s.has_conflicts or $dms == "conflict" then
         {action:"resolve-conflicts", why:"merge conflict with \($s.base)"}
    elif $dms == "need_rebase" then
         {action:"rebase", why:"the project merges with \($method) and the branch is behind \($s.base)",
          cmd:"glab mr rebase \($mr.iid) --repo \($s.repo)"}
    elif $pl != null and ($pl_on_head | not) then
         {action:"wait", why:"the head pipeline \($pl.id) is for \(($pl.sha // "")[0:8]), not the head \($mr.sha[0:8]); a pipeline for the new head has not been reported yet"}
    elif ($failing | length) > 0 then
         {action:"fix-ci", why:"failed job(s) in pipeline \($pl.id): \($failing | join(", "))"}
    elif $pl != null and ($pl.status == "failed") then
         {action:"triage-ci", why:"pipeline \($pl.id) failed, but no failed job that may not fail was read"}
    elif $pl != null and ($pl.status == "canceled") then
         {action:"triage-ci", why:"pipeline \($pl.id) was canceled — re-run it, do not debug"}
    elif $pl != null and ($pl.status == "manual") then
         {action:"triage-ci", why:"pipeline \($pl.id) waits for a manual job"}
    elif $pl != null and ($pl.status | running) then
         {action:"await-checks", why:"pipeline \($pl.id) is \($pl.status) (\($pending | length) job(s) not finished)"}
    elif ($open_threads | length) > 0 or ($s.blocking_discussions_resolved | not) then
         {action:"resolve-threads", why:"\($open_threads | length) unresolved thread(s)"}
    elif $dms == "requested_changes" then
         {action:"address-comments", why:"a reviewer requested changes"}
    elif $dms == "not_approved" then
         {action:"request-review", reason:"review-required", why:"the merge request needs approval before merging"}
    elif $dms == "ci_must_pass" then
         {action:"triage-ci", why:"the project requires a successful pipeline and none was read for the head \($mr.sha[0:8])"}
    elif $dms == "ci_still_running" or $dms == "external_status_checks" or $dms == "security_policy_pipeline_check" then
         {action:"await-checks", why:"detailed_merge_status: \($dms)"}
    elif $dms == "unchecked" or $dms == "checking" or $dms == "preparing" or $dms == "approvals_syncing" then
         {action:"wait", why:"GitLab has not finished computing mergeability (detailed_merge_status: \($dms))"}
    elif $dms == "merge_time" then
         {action:"wait", why:"the merge request may not be merged before its merge_after time (\($mr.merge_after // "unknown"))"}
    elif $dms == "discussions_not_resolved" then
         {action:"resolve-threads", why:"detailed_merge_status: discussions_not_resolved"}
    elif $dms == "draft_status" then
         {action:"ready", why:"detailed_merge_status: draft_status",
          cmd:"glab mr update \($mr.iid) --ready --repo \($s.repo)"}
    elif $dms == "mergeable" then
      if ($ps.squash_option // "") == "always" then
         {action:"blocked", why:"the project squashes every merge (squash_option: always), and squash is not used"}
      else
         {action:"merge", why:"pipeline, threads and conflicts are clear and GitLab reports mergeable",
          method:$method, cmd:$merge_cmd,
          note:("pr-merge.sh does not merge GitLab merge requests; run cmd, which merges without squashing"
                + (if ($s.approved_by | length) == 0 then ". Nobody has approved this merge request: GitLab does not require it here, the review rule of this skill does" else "" end))}
      end
    else
         {action:"blocked", why:"detailed_merge_status: \($dms) — a gate this script does not resolve; read the merge request: \($mr.web_url // "")"}
    end )
