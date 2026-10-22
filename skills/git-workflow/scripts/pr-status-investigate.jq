# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# The jq program of investigate_evidence() in pr-status.sh, kept in a
# file for the same reason as pr-status-evaluate.jq (#395).
    ($gf[0]) as $g | ($rf[0]) as $r | ($protf[0]) as $prot | ($crf[0]) as $cr | ($csf[0]) as $cs
    | ($g.data.repository.pullRequest) as $p
    | ($p.commits.nodes[0].commit.oid) as $head
    | ($p.commits.nodes[0].commit.statusCheckRollup.contexts) as $rollup_conn
    | ($rollup_conn.nodes // []) as $rollup
    # The rollup is read with contexts(first:100). Past that, a run absent from
    # the first page may be on the next one, so nothing is claimed absent.
    | (($rollup_conn.pageInfo.hasNextPage // false) or (($rollup | length) >= 100)) as $truncated
    | ([$rollup[] | (.name // .context)]) as $rollup_names
    | (($prot | type) == "object") as $has_prot
    | ([$p.reviews.nodes[]? | select(.commit.oid == $head)
        | select(.author.login != $p.author.login) | select(.state == "APPROVED")
        | .author.login] | unique) as $approvers
    | ([$p.allCommits.nodes[]?.commit | select((.signature.isValid // false) | not) | .oid[0:8]]) as $unsigned
    | ([$r[]? | select(.type == "required_status_checks")]) as $rsc
    | ((if $has_prot then $prot.required_status_checks else null end) // null) as $classic_rsc
    | ([($rsc[] | (.parameters.strict_required_status_checks_policy // false) as $strict
         | {source: "ruleset \(.ruleset_id)", ruleset_id, strict: $strict}),
        (if $classic_rsc != null
         then {source: "classic protection", ruleset_id: null, strict: ($classic_rsc.strict // false)}
         else empty end)
        | if .strict then . + {behind_by: (if $cmp == null then null else $cmp.behind_by end)} else . end]) as $status_rules
    # Classic protection lists contexts twice: as bare names, and as checks
    # that may name an app. An app is taken only from a positive app_id;
    # anything else is shown as any source rather than interpreted.
    | ([$rsc[] | .ruleset_id as $id | .parameters.required_status_checks[]?
        | {context, integration_id: (.integration_id // null), source: "ruleset \($id)"}]
       + (if $classic_rsc != null
          then ([($classic_rsc.checks // [])[]
                 | {context, integration_id: (if ((.app_id // 0) > 0) then .app_id else null end),
                    source: "classic protection"}]) as $checks
               | $checks
                 + [($classic_rsc.contexts // [])[] | . as $c
                    | select(([$checks[].context] | index($c)) == null)
                    | {context: $c, integration_id: null, source: "classic protection"}]
          else [] end)) as $reqs
    | ([$reqs[] | . as $q
        | (if $cr_ok then [$cr[] | select(.name == $q.context)] else null end) as $runs
        | (if $runs == null then null
           elif $q.integration_id == null then $runs
           else [$runs[] | select(.app.id == $q.integration_id)] end) as $matching
        | (if ($matching // []) | length == 0 then null
           else ($matching | max_by([(if .status != "completed" then 1 else 0 end), (.started_at // "")])) end) as $latest
        | ([$rollup[] | select(.context == $q.context) | .state] | first) as $status_state
        | {context: $q.context, source: $q.source,
           required_integration_id: ($q.integration_id // "any"),
           reported_by_apps: (if $runs == null then null else ($runs | map(.app.id) | unique) end),
           state: (if $runs == null then "unknown, check-runs not fetched"
                   elif $latest != null
                     then (if $latest.status == "completed" then $latest.conclusion else $latest.status end)
                   elif ($runs | length) > 0 then "reported only by another app"
                   elif $status_state != null then "commit status \($status_state | ascii_downcase)"
                   elif $truncated then "no check-run; commit statuses not compared (rollup truncated at 100)"
                   else "missing" end)}
        | .flag = (if .state == "unknown, check-runs not fetched" then "unknown"
                   elif .state == "missing" then "missing"
                   elif (.state | startswith("no check-run;")) then "not-compared"
                   elif .state == "reported only by another app" then "integration-mismatch"
                   elif (.state == "success" or .state == "skipped" or .state == "neutral"
                         or .state == "commit status success") then null
                   else "not-passing" end)]) as $contexts
    # Each read decides only its own lines: failed suites need the suites
    # read; the comparison with the rollup additionally needs the check-runs
    # and a rollup that was not cut off at 100.
    | (if $cr_ok | not then "not compared (check-runs not read)"
       elif $truncated then "not compared (rollup truncated at 100)"
       else "compared" end) as $rollup_comparison
    | (if $cs_ok then
         [$cs[] | select(.conclusion as $c
                         | ["failure", "cancelled", "timed_out", "action_required", "startup_failure", "stale"] | index($c))
          | .id as $sid
          | {suite_id: .id, app: (.app.slug // null), app_id: (.app.id // null), conclusion,
             check_runs: (if $cr_ok then [$cr[] | select(.check_suite.id == $sid) | .name] else null end),
             rollup_comparison: $rollup_comparison}
          | ([(.check_runs // [])[] | select(. as $n | ($rollup_names | index($n)) == null)]) as $absent
          | .outside_rollup = (if $rollup_comparison == "compared" then $absent else null end)
          | select(.check_runs == null or (.check_runs | length) == 0 or ($absent | length) > 0)]
       else null end) as $hidden
    | ([$r[]? | select(.type == "pull_request") | .parameters as $pp
        | {ruleset_id,
           required_approving_review_count: ($pp.required_approving_review_count // 0),
           approvals_on_head: ($approvers | length), approvers: $approvers,
           require_last_push_approval: ($pp.require_last_push_approval // false),
           require_extra_approval_for_unattributed_changes: ($pp.require_extra_approval_for_unattributed_changes // false),
           require_code_owner_review: ($pp.require_code_owner_review // false),
           required_review_thread_resolution: ($pp.required_review_thread_resolution // false),
           dismiss_stale_reviews_on_push: ($pp.dismiss_stale_reviews_on_push // false)}]) as $pr_rules
    | ({fetched: $prot_state, error: (if $prot_err == "" then null else $prot_err end)}
       + (if $has_prot then
            {required_pull_request_reviews:
               ($prot.required_pull_request_reviews // null
                | if . == null then null else
                    {required_approving_review_count: (.required_approving_review_count // 0),
                     approvals_on_head: ($approvers | length),
                     dismiss_stale_reviews: (.dismiss_stale_reviews // false),
                     require_code_owner_reviews: (.require_code_owner_reviews // false),
                     require_last_push_approval: (.require_last_push_approval // false)} end),
             required_conversation_resolution: ($prot.required_conversation_resolution.enabled // false),
             required_signatures: ($prot.required_signatures.enabled // false),
             enforce_admins: ($prot.enforce_admins.enabled // false),
             required_status_checks:
               (if $classic_rsc == null then null
                else {strict: ($classic_rsc.strict // false),
                      contexts: (([($classic_rsc.contexts // [])[]] + [($classic_rsc.checks // [])[].context]) | unique)} end)}
          else {} end)) as $classic
    | ([ ($status_rules[] | select(.strict)
          | (if .ruleset_id == null then "classic branch protection" else "ruleset \(.ruleset_id)" end) as $who
          | if .behind_by == null
            then "\($who) requires the branch to be up to date (strict) and whether the head is behind \($p.baseRefName) could not be read"
            elif .behind_by > 0
            then "\($who) requires the branch to be up to date (strict) and the head is \(.behind_by) commit(s) behind \($p.baseRefName)"
            else empty end),
         # A read that failed is itself an open item, named once, so an empty
         # candidate list can only mean every read succeeded.
         (if $cr_ok then empty else "the check-runs of the head could not be read — which app reported each required context, and its state, is unknown" end),
         (if $cs_ok then empty else "the check suites of the head could not be read — failed suites outside the rollup are unknown" end),
         (if $prot_state == "failed" then "classic branch protection of \($p.baseRefName) could not be read (\($prot_err)) — its review, signature and status-check gates are unknown" else empty end),
         ($contexts[] | select(.flag != null and .flag != "unknown")
          | "required context \(.context) (\(.source)): \(.flag), state \(.state), required app \(.required_integration_id), reported by \(if .reported_by_apps == null then "unknown" elif (.reported_by_apps | length) == 0 then "nobody" else (.reported_by_apps | map(tostring) | join(",")) end)"),
         ($hidden // [] | .[]
          | if .outside_rollup != null
            then "check suite \(.suite_id) (\(.app // "unknown app")) concluded \(.conclusion) and is absent from the GraphQL rollup: \(if (.outside_rollup | length) > 0 then (.outside_rollup | join(", ")) else "no check-run listed" end) — whether it gates the merge is not determined"
            elif .check_runs == null
            then "check suite \(.suite_id) (\(.app // "unknown app")) concluded \(.conclusion); its check-runs could not be read, so whether they are in the GraphQL rollup is not determined"
            else "check suite \(.suite_id) (\(.app // "unknown app")) concluded \(.conclusion); its check-runs (\(if (.check_runs | length) > 0 then (.check_runs | join(", ")) else "none listed" end)) were not compared with the GraphQL rollup, which is truncated at 100 — whether it gates the merge is not determined"
            end),
         ($pr_rules[]
          | (if .approvals_on_head < .required_approving_review_count
             then "ruleset \(.ruleset_id) requires \(.required_approving_review_count) approving review(s); \(.approvals_on_head) on the head as counted by this script"
             else empty end),
            (if .require_last_push_approval then "ruleset \(.ruleset_id) sets require_last_push_approval — rule set, not evaluable by this script" else empty end),
            (if .require_extra_approval_for_unattributed_changes then "ruleset \(.ruleset_id) sets require_extra_approval_for_unattributed_changes — rule set, not evaluable by this script" else empty end),
            (if .require_code_owner_review then "ruleset \(.ruleset_id) sets require_code_owner_review — rule set, not evaluable by this script" else empty end)),
         ($classic.required_pull_request_reviews // empty
          | (if .approvals_on_head < .required_approving_review_count
             then "classic branch protection requires \(.required_approving_review_count) approving review(s); \(.approvals_on_head) on the head as counted by this script"
             else empty end),
            (if .require_last_push_approval then "classic branch protection sets require_last_push_approval — rule set, not evaluable by this script" else empty end),
            (if .require_code_owner_reviews then "classic branch protection sets require_code_owner_reviews — rule set, not evaluable by this script" else empty end)),
         (if ($classic.required_signatures // false) and ($unsigned | length) > 0
          then "classic branch protection requires signed commits and \($unsigned | length) commit(s) carry no valid signature: \($unsigned | join(", "))"
          else empty end)
       ]) as $candidates
    | {cause_determined: false,
       fetched: {check_runs: $cr_ok, check_suites: $cs_ok, compare: $cmp_state, classic_protection: $prot_state},
       rules: [$r[]? | {type, ruleset_id}],
       classic_protection: $classic,
       rollup_truncated: $truncated,
       status_check_rules: $status_rules,
       required_contexts: $contexts,
       failed_suites_outside_rollup: $hidden,
       pull_request_rules: $pr_rules,
       candidates: $candidates,
       summary: (if ($candidates | length) > 0
                 then "\($candidates | length) candidate(s) listed; the cause is not determined and none of them is a verdict"
                 else "no candidate found in the data this script reads; the cause is not determined and lies outside it" end)}
