# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: Netresearch DTT GmbH
# The jq program of evaluate() in pr-status.sh, kept in a file because
# Windows caps a whole command line at 32767 characters and this program
# alone is longer (#395). The payloads arrive on stdin as four JSON
# documents, in the order the first lines bind them.
    [inputs] as $in
    | if ($in | length) != 4
      then error("expected 4 JSON documents on stdin (GraphQL answer, rules, protection, runs), got \($in | length)")
      else . end
    | $in[0] as $g | $in[1] as $r | $in[2] as $prot | $in[3] as $runs |
    # Defined once and used by BOTH the error list and the $head_reviews filter.
    # Two hand-kept copies would have to stay byte-identical: loosening one to
    # match a third error body and not the other puts the row back into
    # $head_reviews, which is exactly the merge-on-an-unread-PR bug again.
    def is_errored_copilot_review:
      ((.author.login // "") | test("copilot"; "i"))
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
                              # A failed Actions job with zero steps whose
                              # annotation reads "The job was not started because
                              # it repeatedly failed to be acquired" never got a
                              # runner. Nothing in the PR can fix that, so it is
                              # named apart from a real failure. Other zero-step
                              # failures (billing, a broken workflow file) carry a
                              # different message and stay FAIL; so do third-party
                              # check runs, which have no workflowRun.
                              elif .conclusion == "FAILURE" and (.steps.totalCount // null) == 0
                                   and (.checkSuite.workflowRun // null) != null
                                   and any(.annotations.nodes[]?; (.message // "") | test("failed to be acquired"))
                                then "NOSTART"
                              else "FAIL" end), url: .detailsUrl, started: .startedAt,
                run: (.checkSuite.workflowRun.databaseId // null),
                suite_done: ((.checkSuite.status // "COMPLETED") == "COMPLETED")}
          else {name: .context, state: (if .state == "SUCCESS" then "PASS"
                                        elif .state == "PENDING" then "PENDING"
                                        else "FAIL" end), url: .targetUrl}
          end]) as $checks
    # One head can carry several check-runs of the SAME name: a close/reopen,
    # a workflow_dispatch or a `gh run rerun` of a superseded run starts a new
    # run whose rows join the old ones in the rollup instead of replacing
    # them. The GitHub merge state reads only the newest row per name; counting
    # the old one answered triage-ci on a CLEAN pull request, and pr-merge.sh
    # refused a merge the gate had already opened (t3x-nr-image-optimize#173:
    # fuzz red at 15:03, green at 18:30, one SHA). Keep the newest row per
    # name — and a row that has not finished outranks every finished one
    # regardless of timestamp: a re-run sits in the queue with startedAt
    # null, and ranking it by "" would hand the name back to the finished
    # row it is about to replace. Status contexts carry no startedAt and are
    # unique per context, so the fallback only ever compares a row with
    # itself.
    | ($checks | group_by(.name)
               | map(max_by([(if .state == "QUEUED" or .state == "PENDING" then 1 else 0 end),
                             (.started // "")]))) as $checks
    # Effective required contexts are the UNION of both sources. The rules
    # endpoint misses classic branch protection and classic protection misses
    # rulesets, and a repository can carry either or both. Taking only the
    # rules endpoint reported `required_contexts: []` on a repo whose five
    # required checks all came from classic protection, which then read as
    # "nothing is required" and fell through to `investigate` with everything
    # green — the question the tool exists to answer (#329,
    # netresearch/orocommerce-skill#20).
    #
    # $prot is fetched lazily, only when the PR is BLOCKED or a review is
    # demanded — which is exactly the state an unreported required context
    # produces, so the classic half is present whenever it decides anything.
    | (([$r[]? | select(.type=="required_status_checks")
         | .parameters.required_status_checks[]?.context]
        + (if ($prot | type) == "object"
           then ($prot.required_status_checks.contexts? // [])
           else [] end))
       | unique) as $required
    # Required contexts with no check-run at all. A context that never
    # reported is invisible on the PR page — the rollup only lists what ran —
    # so this reads as BLOCKED with everything green.
    | ([$required[] | select(. as $c | ($checks | map(.name) | index($c)) == null)]) as $undispatched
    # A required context whose only check-run comes from an OLDER run of its
    # workflow, while the NEWEST run of that workflow on this head carries no
    # check-run of that name. The rollup keeps the old row, so the context
    # counts as reported here, but GitHub shows it as Expected and keeps the
    # PR BLOCKED. Observed on netresearch/t3x-nr-image-optimize#207: workflow
    # Checks ran as #212 (with security / Composer Audit) and as #213 for the
    # ready_for_review action, where the calling job was skipped by an if:
    # and the context never appeared. Re-running the job inside #212 did not
    # clear the block; removing the context from the ruleset did.
    # INFERENCE, not documented by GitHub: a required Actions context is
    # evaluated against the newest run of the workflow that produces it.
    # Deliberately conservative, because a false cause is worse than the
    # honest investigate below:
    #   - newer means a higher runNumber in the same workflow (monotonic per
    #     workflow; createdAt ties within a second);
    #   - the same event only: a push run and a pull_request run of one SHA
    #     legitimately carry different jobs;
    #   - the newest run must be COMPLETED, since a running one may still
    #     register the job;
    #   - a rollup truncated at 100 proves no absence, so nothing is flagged.
    # Read from the rollup before the per-name dedupe, which would drop the
    # rows that show two runs; it costs no call. Only the rung directly above
    # investigate reads it.
    | ($p.commits.nodes[0].commit.statusCheckRollup.contexts) as $rollup_conn
    | ([$rollup_conn.nodes[]?
        | select(.__typename == "CheckRun" and (.checkSuite.workflowRun.workflow.databaseId // null) != null)
        | {name, suite_status: .checkSuite.status, run: .checkSuite.workflowRun}]) as $wf_rows
    | (if ($rollup_conn.pageInfo.hasNextPage // false) then []
       else [$required[] as $c
             | ([$wf_rows[] | select(.name == $c)] | max_by(.run.runNumber)) as $src
             | select($src != null)
             | ([$wf_rows[] | select(.run.workflow.databaseId == $src.run.workflow.databaseId
                                     and .run.event == $src.run.event)]
                | max_by(.run.runNumber)) as $latest
             | select($latest.run.runNumber > $src.run.runNumber
                      and $latest.suite_status == "COMPLETED")
             | {context: $c, workflow: $src.run.workflow.name,
                reported_in: ($src.run | {run_id: .databaseId, run_number: .runNumber, event, created_at: .createdAt, url}),
                newest_run: ($latest.run | {run_id: .databaseId, run_number: .runNumber, event, created_at: .createdAt, url})}]
       end) as $stale_required
    | ([$r[]? | .type] | unique) as $ruletypes
    | (($ruletypes | index("copilot_code_review")) != null) as $needs_copilot
    | ($p.author.login) as $author
    # A bot author can never post the attestation below: it authenticates as
    # nobody and reviews nothing, so the whole `Self-review:` path is closed on
    # a Renovate or Dependabot pull request and the advice has to name a
    # different one (#280). Same predicate as $unanswered_human further down —
    # __typename is the authority, the login patterns are the fallback for a
    # REST-shaped author and for App-backed User accounts.
    # Every alternative is anchored, and each covers a form measured on a real
    # Renovate pull request: GraphQL answers login `renovate` with __typename
    # Bot, `gh pr view --json author` answers `app/renovate`, and the webhook
    # payload answers `renovate[bot]`. An unanchored `^renovate` would also
    # read the human login `renovate-maintainer` as a bot, which refuses that
    # person --self-reviewed on their own pull request.
    | ((($p.author.__typename // "") == "Bot")
       or ($author | test("\\[bot\\]$|^app/|^(dependabot|renovate)$"; "i"))) as $author_is_bot
    # A bot author is one way the attestation becomes unavailable; finishing
    # a pull request you did not author is the other, and it was the one this advice
    # used to miss. pr-merge.sh --self-reviewed refuses EVERY authenticated user
    # who is not the author, so recommending it to a non-author recommends an
    # action that cannot succeed — measured on netresearch/concourse-ci-skill#57,
    # author aseemann, viewer CybotTM, where the advice was printed on every read
    # and then refused at merge time. An empty viewer (an older gh, a stubbed
    # response) counts as somebody else: the attestation belongs to the author alone,
    # and an account that cannot be named cannot be shown to be the author.
    | (($g.data.viewer.login // "")) as $viewer
    | ($viewer != "" and $viewer == $author) as $viewer_is_author
    | ((($author_is_bot | not) and $viewer_is_author)) as $attestation_available
    # A non-author who pushed commits onto the branch reviewed nothing they did
    # not also write. Approving then is a self-approval: it attests to no second
    # reader, and an agent harness may refuse it outright — measured on
    # netresearch/retro-skill#164, author juanazadian, viewer CybotTM with three
    # of four commits, where the advice "--approve" was denied as self-approval
    # and the operator was left without a named path.
    # Merge commits do not count: "Update branch", or the base merged in by
    # hand, is written in the name of the viewer and carries none of their code.
    | ([$p.allCommits.nodes[]?.commit
        | select((.parents.totalCount // 1) < 2)
        | select([.authors.nodes[]?.user.login // empty] | index($viewer))] | length) as $viewer_commits
    | ($viewer != "" and ($viewer_is_author | not) and $viewer_commits > 0) as $viewer_committed
    # The query reads one page: 100 commits, 10 authors each. Past that, whether
    # the viewer wrote a commit is unknown, and unknown must not read as "no".
    | ($p.allCommits.nodes // [] | length) as $commits_read
    | ($p.allCommits.totalCount // $commits_read) as $commits_total
    | ($commits_total <= $commits_read
       and all($p.allCommits.nodes[]?.commit;
               (.authors.totalCount // 0) <= (.authors.nodes // [] | length))) as $authorship_complete
    # Self-review attestation (#203). An EXPLICIT operator assertion, not an
    # observation: a PR comment BY THE AUTHOR whose body carries a line
    # `Self-review: <sha>` prefix-matching the current head. This is the
    # deliberate difference from the removed "review-yourself" action (see the
    # ladder comment below): the tool still observes nothing about whether a
    # human read the diff — the author asserts it, on the record, and the
    # record dies with the next push because the sha stops matching. Whether
    # the attestation may satisfy the review gate is decided in the ladder,
    # and only where the demanded review is one an exhausted Copilot quota
    # makes unsatisfiable — with a live review path it changes nothing.
    # At least the first 12 chars of the head sha (48 bits): an 8-char prefix
    # is a 32-bit binding that vanity-sha grinders defeat in minutes, which
    # would let anyone with push access keep an attestation alive across an
    # unreviewed push. pr-merge posts the full 40-char oid.
    | ([$p.comments.nodes[]? | select(.author.login == $author)
        | select((.body // "") | test("(^|\\n)Self-review: " + $head[0:12]))]) as $self_review_comments
    | (($self_review_comments | length) > 0) as $self_review_on_head
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
    | ([$head_reviews[] | select((.author.login // "") | test("copilot"; "i"))]) as $copilot_on_head
    | ([$p.reviewThreads.nodes[]? | select(.isResolved == false)]) as $unresolved
    # Prose written under the pull request is an ISSUE comment, not a review
    # thread and not a review. It appears in neither reviewThreads nor the
    # check rollup, so a report built from those alone says "0 unresolved"
    # while findings from a maintainer sit unread. Anything posted after the
    # last word of the author is unanswered by construction; if the author
    # never commented, every comment by someone else is.
    #
    # Whose last word, though. Normally the one from the author: you opened the
    # pull request, someone wrote under it, you answer. On a BOT-authored pull
    # request that breaks. The author posts once at creation and never again, so
    # every later comment stays counted for the life of the PR, the approval
    # note from the reviewing human included, and answering adds one more
    # comment that is counted too. The rung then never clears and pr-merge.sh
    # refuses a pull request that is CLEAN, green, thread-free and approved
    # (#319, observed on netresearch/t3x-contexts_geolocation#56). The question
    # the rung asks is "did I leave something unanswered", so on a bot PR the
    # answering party is the viewer. $author_is_bot is the same predicate the
    # attestation path above uses. Falling back to $author keeps the old
    # behaviour when viewer is absent — an older gh, or a stubbed response —
    # rather than making every comment unanswered by comparing against "".
    | (if $author_is_bot and $viewer != "" then $viewer else $author end) as $responder
    | (([$p.comments.nodes[]? | select(.author.login == $responder) | .createdAt] | max) // "") as $responder_last_comment
    | ([$p.comments.nodes[]? | select(.author.login != $responder)
                            | select(.createdAt > $responder_last_comment)]) as $unanswered_comments
    # Bots are reported but never drive the ladder: a Renovate or Dependabot
    # note must not push its own PR off the auto-merge rung it exists to reach.
    # __typename is the authority, not the login. GraphQL returns Bot for an
    # App and strips the [bot] suffix REST appends, so a login test alone reads
    # "github-actions" and "sonarqubecloud" as people — measured on this very
    # pull request, whose CI comments took it off the merge rung on the first
    # attempt. The login patterns stay as a fallback for callers that supply a
    # REST-shaped author, and for App-backed User accounts.
    # A comment written by the person this report is addressed to is answered by
    # construction, so the viewer is dropped the way bots are (#308). The rung
    # measures against the AUTHOR everywhere the author is a person, and on a
    # fork pull request finished by a maintainer the author often never comments
    # at all: every maintainer comment is then newer than an empty
    # $responder_last_comment, the counter rises with each one written, and
    # answering the bot notices raises it again. Observed on
    # netresearch/usercentrics-widgets#143 and netresearch/retro-skill#106 —
    # CLEAN, green, thread-free, APPROVED, and pr-merge.sh refusing. What this
    # does NOT touch: a comment by somebody else after the last word still
    # raises the rung, which is the case the rung exists for.
    | ([$unanswered_comments[]
        | select(((.author.__typename // "") == "Bot") | not)
        | select(((.author.login // "") | test("\\[bot\\]$|^(dependabot|renovate|copilot)"; "i")) | not)
        | select($viewer == "" or .author.login != $viewer)]) as $unanswered_human
    # The CodeRabbit verdict is an ISSUE COMMENT, never a review, so every
    # review-shaped field above is blank on a pull request it cleared minutes
    # ago and the report reads "NONE on current head". It keeps ONE comment and
    # edits it in place, accumulating a block per push, each naming the range it
    # covers — so the marker ABOVE the line naming a head is the verdict for
    # that head, and a head named by no line was never reviewed. Same algorithm as
    # references/pull-request-workflow.md, which until now only a human could
    # run. REPORTED, NOT MERGED ON: has_review_on_head and the merge gate are
    # untouched, because a comment is not a review and widening that test here
    # would let every bot comment clear the gate.
    # "It keeps ONE comment" holds for the SUMMARY only. A reply to
    # `@coderabbitai review` is a second comment by the same author, and it is
    # the later one — so taking the last CodeRabbit comment reads the reply
    # ("Already reviewed the last commit") and reports a reviewed head as never
    # reviewed. Measured against netresearch/matrix-skill#151, where the
    # 512-character reply sat after the 7334-character summary. Pick the comment
    # that names the head instead of the newest one. GraphQL returns the login
    # without the [bot] suffix REST appends, hence the prefix match. Only Bot
    # accounts count: since a verdict of in-progress holds a watch, a user
    # whose login merely starts with coderabbitai must not be able to post
    # one (raised by CodeRabbit on netresearch/git-workflow-skill#383).
    | ([$p.comments.nodes[]? | select((.author.login // "") | test("^coderabbitai"; "i"))]) as $cr_comments
    | ([$cr_comments[] | select((.author.__typename // "Bot") == "Bot")]) as $cr_bot
    | ([$cr_bot[] | .body // ""]) as $cr_bodies
    # Between `@coderabbitai review` and the summary naming the head, the only
    # trace of the review is the reply, which reads "Review triggered." until
    # CodeRabbit edits it to the outcome ("Review finished.", "Review rate
    # limited."). Unanswered by that summary, the head reads "none", and a
    # watch that settles on it returns while the review runs: measured on
    # netresearch/retro-skill#169, reply at 10:39:34, summary at 10:39:45, the
    # watch gone in between. Bound to the head by time, so a reply left over
    # from an earlier head does not count; with the commit date unreadable it
    # counts, because in-progress only ever holds a watch and opens nothing.
    # It outranks a summary block that already names the head: a head refused
    # as rate limited and then requested again keeps that block until the new
    # review lands, and reading it would settle the watch over the review.
    # Before even that reply exists, the request itself is the trace: on
    # netresearch/git-workflow-skill#383 CodeRabbit posted no reply at all and
    # answered 9 minutes later by editing the summary. A request counts until
    # a CodeRabbit comment is written or edited after it, and only where
    # CodeRabbit has commented on the PR before, so a repository without it
    # does not wait for an answer that never comes.
    | ($p.commits.nodes[0].commit.committedDate // "") as $cr_head_at
    | ([$cr_bot[] | (.lastEditedAt // .createdAt // "")] | max // "") as $cr_last_word
    | ([$cr_bot[] | select((.body // "") | test("Review triggered\\."))
                  | select((.createdAt // "") > $cr_head_at)] | length > 0) as $cr_reply_open
    | (($cr_bot | length) > 0 and
       ([$p.comments.nodes[]? | select((.author.login // "") | test("^coderabbitai"; "i") | not)
                             | select((.body // "") | test("@coderabbitai (full )?review"))
                             | select((.createdAt // "") > $cr_head_at)
                             | select((.createdAt // "") > $cr_last_word)] | length > 0)) as $cr_request_open
    | ($cr_reply_open or $cr_request_open) as $cr_triggered
    | (([$cr_bodies[] | select(test($p.headRefOid))] | last // "") | split("\n")) as $cr_lines
    | ([$cr_lines | to_entries[] | select(.value | test($p.headRefOid)) | .key] | first) as $cr_idx
    # The summary also comes in a shape that names the head it assessed as a
    # SHORT sha and carries no range at all ("Merge Risk: … up to `2cf7a`").
    # Resolving it needs `git rev-parse` against a checkout that has fetched the
    # branch, which this script cannot assume, and a prefix compare is exactly
    # the wrong shortcut — five hex digits collide, and a collision reports an
    # older assessment as covering the current head. So the presence of that
    # marker downgrades "none" to "unknown" and the reader is sent to the
    # reference to resolve it. Never to "clean": unknown authorises nothing.
    # Searched across every CodeRabbit comment, not only the one naming the
    # head: when no comment names it, there are no $cr_lines to search.
    | (([$cr_bodies[] | select(test("up to `[0-9a-f]+`"))] | length) > 0) as $cr_short_shape
    | (if $cr_triggered then "in-progress"
       elif ($cr_bodies | length) == 0 then "none"
       elif $cr_idx == null then (if $cr_short_shape then "unknown" else "none" end)
       else (([$cr_lines[0:$cr_idx][]
               | if test("rate limited by coderabbit") then "rate-limited"
                 elif test("Currently processing new changes") then "in-progress"
                 elif test("No actionable comments") then "clean"
                 elif test("Actionable comments posted") then "findings"
                 else empty end] | last) as $positional
              # The positional rule stays authoritative: one body carries a
              # block per push, so "which marker is nearest above this head" is
              # the only way to keep an older block from answering for a newer
              # one. Walkthrough is a separate FALLBACK, reached only when no
              # block marker precedes the head at all — the shape a finished
              # review WITH findings has: a walkthrough, a risk table, and no
              # "No actionable comments" line anywhere. Measured on
              # netresearch/git-workflow-skill#312. A clean summary carries a
              # walkthrough too, but BELOW the line naming its range, so the two
              # shapes are distinguishable by position; keeping this out of the
              # scan is about not mixing a section heading in with the block
              # markers, not about a collision that exists today.
              | if $positional != null then $positional
                elif ([$cr_lines[0:$cr_idx][] | select(test("Walkthrough"))] | length) > 0
                  then "findings"
                else "unknown" end)
       end) as $cr_verdict
    # SonarCloud reports in one comment headed "Quality Gate passed" or
    # "Quality Gate failed", and a PASSED gate can still list new issues: the
    # default gate fails on ratings, coverage and duplication, not on the count,
    # so a code smell such as python:S3776 lands on main with every check
    # green. Measured on netresearch/data-tools-skill#97: "Quality Gate
    # passed", "[1 New issue]", merged, and the finding then stood open on
    # main. The count is read from the newest SonarCloud comment; the comment
    # names no commit, so it is the latest analysis, not provably this head.
    # Information only: NEXT and the merge gate never read it. null when no
    # SonarCloud comment exists or its body carries no count.
    | ([$p.comments.nodes[]? | select((.author.login // "") | test("^sonar(qube)?cloud"; "i"))
                             | select((.author.__typename // "Bot") == "Bot")]
       | sort_by(.lastEditedAt // .createdAt // "") | last) as $sonar_comment
    | ([($sonar_comment.body // "") | capture("\\[(?<n>[0-9]+) New issues?\\]")]
       | first | if . == null then null else (.n | tonumber) end) as $sonar_new_issues
    # A cancelled context that reported again under the same name is STALE:
    # the later row is the answer and the cancelled one is a leftover. One that
    # never reported again is genuinely unmet and still shuts the gate — but it
    # needs a re-run, not a fix, so it is named separately either way.
    | ([$checks[] | select(.state=="PASS" or .state=="SKIP" or .state=="FAIL") | .name]) as $reported
    | ($checks | map(select(.state=="CANCEL" and (.name as $n | $reported | index($n)))))     as $stale
    | ($checks | map(select(.state=="CANCEL" and (.name as $n | $reported | index($n)) == null))) as $cancelled
    | ($checks | map(select(.state=="NOSTART"))) as $not_started
    | (($checks | map(select(.state=="FAIL"))) + $cancelled + $not_started) as $failing
    | ($checks | map(select(.state=="QUEUED"))) as $queued
    | ($checks | map(select(.state=="PENDING"))) as $running
    # "pending" downstream keeps meaning "not finished", queued or running.
    | ($queued + $running) as $pending
    | ($failing | map(select(.name as $n | $required | index($n)))) as $failing_required
    | ($pending | map(select(.name as $n | $required | index($n)))) as $pending_required
    | ($queued  | map(select(.name as $n | $required | index($n)))) as $queued_required
    # Right after a push every check is queued and none is running, which is
    # normal for a few seconds and says nothing about runner capacity. Age the
    # signal before acting on it. The 5-minute threshold is this script owning
    # a conservative freshness floor — NOT the merge queue tolerance: that is
    # check_response_timeout_minutes, which the REST docs give no default for
    # and which is configured per ruleset (30 and 60 on the two netresearch
    # repos checked, #233).
    | (($queued_required | map(.started // empty) | min) // null) as $oldest_q
    | (if $oldest_q == null then 0
       else (((now - ($oldest_q | fromdateiso8601)) / 60) | floor) end) as $queued_minutes
    | {
        repo: $repo.nameWithOwner, number: $p.number, title: $p.title,
        state: $p.state, draft: $p.isDraft,
        mergeable: $p.mergeable, mergeState: $p.mergeStateStatus,
        reviewDecision: ($p.reviewDecision // ""),
        base: $p.baseRefName, head: $p.headRefName, headOid: $head,
        # The head branch of a fork pull request lives in another repository,
        # which decides whether the merge may delete it.
        cross_repository: ($p.isCrossRepository // false),
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
          not_started: ($not_started|map(.name|gsub("\\s+";" ")|.[0:90])),
          # The runs to re-run, and which of them still have a job going: a
          # run is re-runnable only once all of its jobs have concluded. The
          # check suite of the row is the run, and its status covers jobs the
          # rollup did not list (it is cut at 100 contexts); a pending row in
          # the same run is the second signal.
          not_started_runs: ($not_started|map(.run)|unique),
          not_started_busy_runs: (($not_started|map(.run)|unique) as $ns_runs
                                  | (($not_started|map(select(.suite_done|not)|.run))
                                     + ($ns_runs - ($ns_runs - ($pending|map(.run // empty)))))
                                  | unique),
          # Failures other than not-started ones. Empty while failing is not
          # means every red row is one nobody can fix in the PR.
          failing_other: ($failing|map(select(.state != "NOSTART"))|map(.name)),
          failing_required_other: ($failing_required|map(select(.state != "NOSTART"))|map(.name)),
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
                               and ($checks|length) > 0
                               # A not-started row whose run is still going per
                               # its check suite: not settled either, though no
                               # pending row of that run may be visible.
                               and ($not_started|map(select(.suite_done|not))|length) == 0)
                         else null end),
        rulesets: $ruletypes,
        # Ids of the rulesets whose pull_request rule sets
        # require_last_push_approval. Unlike the classic form this one is
        # readable by every caller: it is a parameter of the rule the rules
        # endpoint already returns, so it needs no admin token.
        last_push_rulesets: ([$r[]? | select(.type == "pull_request"
                                              and (.parameters.require_last_push_approval // false))
                              | .ruleset_id]),
        # Review gates from CLASSIC branch protection, which the rules
        # endpoint never shows (require_last_push_approval, approval count,
        # code-owner reviews). Admin-only endpoint, fetched lazily and only
        # when the PR looks review-blocked — null means "not fetched or not
        # visible", never "no classic protection".
        # Workflow runs on this head that a maintainer has not approved yet.
        # GitHub demands that approval on a fork pull request after EVERY new
        # SHA, and an unapproved run is not a check run at all: it contributes
        # nothing to the rollup, so the rung below reported `0 pending` and
        # pointed at the review gate while eight required contexts had not
        # started (#310). Empty on a same-repository PR, where the fetch is
        # not made.
        awaiting_approval: $runs,
        classic_protection: (if $prot == null or ($prot | type) != "object"
                             then null
                             else ($prot.required_pull_request_reviews // null
                                   | if . == null then null else {
                                       approvals_required: (.required_approving_review_count // 0),
                                       last_push_approval: (.require_last_push_approval // false),
                                       code_owner_reviews: (.require_code_owner_reviews // false)
                                     } end) end),
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
        # clean | findings | in-progress | rate-limited | unknown | none.
        # Display and advice only — nothing downstream gates on it. "unknown"
        # covers the short-sha shape, which only a checkout can resolve, and a
        # block whose marker this script does not know.
        coderabbit_on_head: $cr_verdict,
        # New issues in the newest SonarCloud Quality Gate comment, or null.
        # Display only — see $sonar_new_issues above.
        sonar_new_issues: $sonar_new_issues,
        has_copilot_review_on_head: (($copilot_on_head|length) > 0),
        # Which of the two came last, not merely which exists. reviews(last:50)
        # is chronological, so the final Copilot row on this head decides: a
        # delivered review after an errored quota row means the wall lifted, and
        # an errored row after a delivered one means it is back. Asking only
        # "is there a review" would clear the marker in the second case too.
        copilot_latest_on_head_ok:
          (([$reviews_raw[] | select((.author.login // "") | test("copilot"; "i"))] | last)
           | if . == null then false else (is_errored_copilot_review | not) end),
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
        # True when the PR author posted a `Self-review: <head-sha>` comment
        # for the CURRENT head — the explicit attestation, not a review row.
        # Whether it satisfies anything is the ladder decision; this field
        # only reports that the record exists.
        self_review_on_head: $self_review_on_head,
        self_review_url: (if $self_review_on_head
                          then ($self_review_comments | last | .url)
                          else null end),
        author: $author,
        author_is_bot: $author_is_bot,
        viewer: $viewer,
        viewer_is_author: $viewer_is_author,
        attestation_available: $attestation_available,
        viewer_commits: $viewer_commits,
        viewer_committed: $viewer_committed,
        authorship_complete: $authorship_complete,
        commits_read: $commits_read,
        commits_total: $commits_total,
        requested_reviewers: [$p.reviewRequests.nodes[]?.requestedReviewer|(.login // .slug)],
        unresolved_threads: ($unresolved|length),
        unanswered_comments: ($unanswered_comments|length),
        unanswered_human: ($unanswered_human|length),
        unanswered_by: ([$unanswered_comments[]|.author.login]|unique),
        unanswered_urls: ([$unanswered_comments[]|.url]),
        # After a review round the body often still explains the approach the
        # fix replaced, and nothing on the report pointed at it. Information
        # only: the NEXT ladder and the merge gate never read this. It compares
        # timestamps and cannot tell whether the body is still true; a head
        # committed after the last edit is the moment to re-read it. The
        # committer date, not the push time, which GraphQL no longer gives.
        # Both values are UTC ISO-8601, so the string comparison orders them,
        # as the comments comparison above does. null when either is missing.
        body_freshness: (($p.lastEditedAt // $p.createdAt // null) as $edited
                         | ($p.commits.nodes[0].commit.committedDate // null) as $committed
                         | {edited_at: $edited,
                            edited: ($p.lastEditedAt != null),
                            head_committed_at: $committed,
                            older_than_head: (if $edited == null or $committed == null then null
                                              else ($committed > $edited) end)}),
        threads: [$unresolved[]|{threadId: .id,
                                 commentId: .comments.nodes[0].databaseId,
                                 author: .comments.nodes[0].author.login,
                                 path: .comments.nodes[0].path,
                                 outdated: .isOutdated}],
        merge_methods: ([ (if $repo.mergeCommitAllowed then "merge" else empty end),
                          (if $repo.rebaseMergeAllowed then "rebase" else empty end),
                          (if $repo.squashMergeAllowed then "squash" else empty end) ]),
        auto_merge_allowed: $repo.autoMergeAllowed,
        # A queue shows either as a merge_queue rule or, when it was set up
        # through classic protection, only as the mergeQueue of the pull
        # request, which GitHub resolves for its base branch.
        queue_active: (($p.mergeStateStatus == "BLOCKED" or $p.mergeStateStatus == "CLEAN")
                       and ((($ruletypes | index("merge_queue")) != null)
                            or ($p.mergeQueue != null))),
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
    # A review is mandatory; a BOT review is not. The attestation used to count
    # only where a Copilot review was unsatisfiable — a quota wall or two
    # failures on this head — which tied the whole self-review path to a bot
    # that most repositories neither require nor have the quota for, and left
    # a repository without the copilot_code_review ruleset with no way to
    # merge a reviewed pull request at all. What the policy demands is that
    # somebody read the diff, and the author reading it is somebody.
    #
    # The one thing still worth waiting for is a bot review actually in
    # flight: requesting a reviewer commits you to waiting for its answer, so
    # a pending Copilot request keeps the attestation inert. Nothing else
    # does, because nothing else is coming.
    #
    # reviewDecision guards: a human CHANGES_REQUESTED is a live review saying
    # no, and REVIEW_REQUIRED means the HOST demands an approval the
    # attestation could never satisfy — in both states the attestation stays
    # inert so the ladder keeps reporting the honest review state instead of
    # falling through to a merge attempt (CHANGES_REQUESTED with no open
    # thread leaves mergeState CLEAN) or to "investigate".
    # The attestation counts only for the PR author themselves: the run must be
    # authenticated as that author. Read by anyone else (a maintainer running
    # this on a pull request somebody else opened), the comment is reported in
    # self_review_on_head but opens nothing; an unknown viewer opens nothing
    # either.
    | ($s.self_review_on_head
       and ($s.viewer != "") and ($s.viewer == $s.author)
       and (($s.requested_reviewers|map(test("copilot";"i"))|any) | not)
       and ($s.reviewDecision != "CHANGES_REQUESTED")
       and ($s.reviewDecision != "REVIEW_REQUIRED")) as $self_attested
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
    # The CodeRabbit clause is appended to the phrase rather than replacing it:
    # a comment does not lift the gate, but omitting it sends the operator to
    # re-derive by hand what this run already read, or to write a self-review
    # note claiming no bot review existed when one did.
    | (if $s.coderabbit_on_head == "clean"
         then " — note CodeRabbit reviewed THIS head and generated no actionable comments;"
              + " that is a comment, not a review, so the gate stands, but say so rather than"
              + " claiming no bot review was obtainable"
       elif $s.coderabbit_on_head == "findings"
         then " — note CodeRabbit posted actionable comments on THIS head; read them before anything else"
       elif $s.coderabbit_on_head == "rate-limited"
         then " — CodeRabbit refused THIS head as rate limited; it will not catch up on its own"
       elif $s.coderabbit_on_head == "in-progress"
         then " — CodeRabbit is still reviewing THIS head; wait for it rather than re-triggering,"
              + " and do not merge over a review in flight"
       elif $s.coderabbit_on_head == "unknown"
         then " — a CodeRabbit summary names the head it assessed as a short sha; resolve it with"
              + " git rev-parse per references/pull-request-workflow.md before treating this head"
              + " as reviewed or as unreviewed"
       else "" end) as $cr_note
    | "no review on the current head (\($s.headOid[0:8])) — do not merge unreviewed\($cr_note)" as $no_review
    | (if ($s.has_review_on_head | not) then "\($no_review). " else "" end) as $unreviewed
    # What a non-author who also pushed commits is told instead of "--approve":
    # approving code you wrote attests to no second reader, and an agent
    # harness may deny it as self-approval (retro-skill#164). The review has to
    # come from someone else, or the merge from the person who owns it.
    | (if $s.viewer_committed
       then " You wrote \($s.viewer_commits) of the commits on this branch, so an approval from you"
            + " would approve your own code: it attests to no second reader, and an agent harness may"
            + " refuse it as self-approval. The review has to come from someone who wrote none of"
            + " them — or the merge from an explicit instruction by whoever owns that decision, with"
            + " the review you did do posted on the PR as a comment"
       else " Only one page of authorship was read (\($s.commits_read) of \($s.commits_total) commits,"
            + " at most 10 authors each), so whether you wrote any of them is unknown. Check the"
            + " whole branch first; approve as yourself only if you wrote none of its commits"
       end) as $co_author_why
    # Only a non-author is offered --approve, so only a non-author can lose it.
    | (($s.attestation_available | not)
       and ($s.viewer_committed or ($s.authorship_complete | not))) as $approve_withheld
    # One quota sentence for every branch that would otherwise hand back a
    # re-request command. Where the evidence came from is stated rather than
    # assumed: on a PR that carries no Copilot row at all, saying the error
    # body names the limit would describe a review that is not there — and the
    # operator could not tell a fresh reading from a remembered one, nor find
    # the file to undo it.
    | (if $s.copilot_quota_hit
       then "the error body on this pull request says the requesting user reached the quota limit"
       else "an earlier run recorded the wall in \($marker_path) — delete that file if it was recorded in error"
       end) as $quota_evidence
    | ("Copilot is OUT OF REVIEW QUOTA — \($quota_evidence). The quota is account-wide, so"
       + " re-requesting on another PR will not get around it right now. When it comes back"
       + " is not something this tool can predict: it has been seen to return within the"
       + " same month and go again minutes later, so the record above expires on its own and"
       + " is dropped as soon as a Copilot review is observed. Review the diff yourself, note"
       + " in the PR that the bot review was unavailable, and decide on that."
       # The attestation is an assertion BY THE AUTHOR, so nobody else can make it
       # and pr-merge.sh --self-reviewed refuses. That is true of a bot-authored
       # pull request (#280) and equally of one you did not author, which this used to read
       # as the attestation path. What is left in both cases is the ordinary review
       # a human can give: an APPROVED review on this head satisfies the policy on
       # its own, in this branch and in the generic one below.
       + (if ($s.attestation_available | not)
          then " The pull request is authored by \($author)"
               + (if $s.author_is_bot then ", a bot that never authenticates and never reads a diff"
                       + (if $s.viewer == "" then " (and the account this run is authenticated as is"
                               + " unknown: the response named no viewer; check gh auth status)"
                          else "" end)
                  elif $s.viewer == "" then ", and the account this run is authenticated as is unknown"
                       + " (the response named no viewer; check gh auth status)"
                  else ", not by you (\($s.viewer))" end)
               + ", so the self-review attestation is not available on it: that attestation is an"
               + " assertion by the author, and pr-merge.sh --self-reviewed refuses every other"
               + " authenticated user."
               + (if $approve_withheld then $co_author_why
                  else " Review the diff and approve it as yourself instead — an"
                     + " approval on this head satisfies the gate, and pr-merge.sh then merges without"
                     + " any flag: gh pr review \($s.number) --repo \($s.repo) --approve" end)
          else " To proceed on a documented self-review, post a PR comment (as the PR author)"
               + " containing the line `Self-review: <head-sha>` with at least the first 12"
               + " chars of \($s.headOid[0:12]) — pr-merge.sh --self-reviewed posts it and merges in"
               + " one step; the attestation is honoured only while this wall stands and dies with"
               + " the next push. The placeholder here is deliberate: this very advice gets pasted"
               + " into PR comments, and a paste must never mint an attestation, so the accepting"
               + " sequence never appears in it"
          end)) as $quota_why
    # Where a signature requirement is KNOWN rather than suspected: classic
    # protection as read (admin-only, null otherwise) or the ruleset rule. The
    # suspected case is the fix-signatures rung further down, whose guards stay.
    | ([(if (($prot | type) == "object") and ($prot.required_signatures.enabled // false)
         then "classic branch protection" else empty end),
        (if ($ruletypes | index("required_signatures")) != null
         then "the required_signatures ruleset" else empty end)]) as $sig_required_by
    # A linear rebase re-signs only a linear history: it drops merge commits,
    # and with them any conflict resolution they carry. Unknown (a second page
    # of commits) counts as having merges.
    | (($p.allCommits.totalCount // 0) > ($p.allCommits.nodes // [] | length)
       or any($p.allCommits.nodes[]?.commit; (.parents.totalCount // 1) >= 2)) as $branch_has_merges
    # CodeQL default setup does not analyze a pull request from a fork, so a
    # code_scanning rule that demands CodeQL results can never be met on its
    # head. Inferred from the absence of every CodeQL row, never measured
    # directly: the code-scanning analyses are not read here.
    | ($s.cross_repository
       and ([$r[]? | select(.type == "code_scanning")
             | .parameters.code_scanning_tools[]?.tool // ""
             | select(test("codeql"; "i"))] | length) > 0
       and ([$checks[] | .name // "" | select(test("^(CodeQL$|Analyze \\()"))] | length) == 0) as $codeql_fork_gap
    | .next =
        (if $s.state != "OPEN" then
           {action:"none", why:"PR is \($s.state)"}
         elif ($s.rules_fetched|not) then
           {action:"rules-unavailable",
            why:"could not read repos/\($s.repo)/rules/branches/\($s.base) — the required-check list is unknown, so no merge verdict is possible from here"}
         elif $s.mergeable == "CONFLICTING" then
           {action:"resolve-conflicts", why:"merge conflict with \($s.base)"}
         elif $s.mergeState == "BEHIND" then
           {action:"rebase", why:"branch is behind \($s.base)",
            cmd:"git fetch origin \($s.base):refs/remotes/origin/\($s.base) && git rebase origin/\($s.base) && git push --force-with-lease"}
         # Every red row is a job that never got a runner, and each of their
         # runs has concluded: nothing in the PR to fix, re-run them. While a
         # run still has a job going, this does not fire; the ladder goes on,
         # so threads and comments still come first, and the wait it ends in
         # names the not-started rows (see the end of the ladder).
         elif ($s.checks.failing|length) > 0 and ($s.checks.failing_other|length) == 0
              and ($s.checks.not_started_busy_runs|length) == 0 then
           {action:"rerun-ci", why:"only not-started job(s) failing: \($s.checks.not_started|join(", ")) — no runner was acquired; nothing in the PR to fix",
            cmd:($s.checks.not_started_runs|map("gh run rerun \(.) --repo \($s.repo) --failed")|join(" && "))}
         # fix-ci and triage-ci name only failures somebody can fix; the
         # not-started rows next to them are named after the ladder.
         elif ($s.checks.failing_required_other|length) > 0 then
           {action:"fix-ci", why:"required check(s) failing: \($s.checks.failing_required_other|join(", "))",
            urls:$s.checks.failing_urls}
         # Only once every required check has concluded. While one is still
         # running, a red non-required check is information: it cannot be what
         # keeps the gate shut yet, and returning an action here ends a --watch
         # that has nothing to act on. The wait branch below names it instead.
         elif (($s.checks.failing_other|length) > 0 and ($s.checks.pending_required|length) == 0) then
           {action:"triage-ci", why:("non-required check(s) failing: \($s.checks.failing_other|join(", ")) — not merge-blocking on their own"
                                     + (if ($s.checks.failing_required|length) > 0
                                        then "; required not-started row(s) keep the gate shut"
                                        else ", but UNSTABLE keeps the gate shut" end)),
            urls:$s.checks.failing_urls}
         elif $s.unresolved_threads > 0 then
           {action:"resolve-threads", why:"\($s.unresolved_threads) unresolved review thread(s)",
            threads:$s.threads}
         # Below resolve-threads, which names a precise line and a thread id,
         # and above draft: a comment left unanswered is real work no matter
         # how the PR is parked. Human comments only — see $unanswered_human.
         elif $s.unanswered_human > 0 then
           {action:"address-comments",
            why:"\($s.unanswered_human) comment(s) posted after your last word by \($s.unanswered_by|join(", ")) — issue comments live outside reviewThreads, so \"0 unresolved\" above does not cover them",
            urls:$s.unanswered_urls}
         # Draft sits BELOW the branches that report real work — a conflict, a
         # stale base, a red check, an open thread all stay worth doing while
         # the PR is deliberately parked as draft (the back-to-draft-on-resume
         # convention) — and ABOVE every review and merge branch, whose advice
         # is meaningless for a draft. While checks still run there is nothing
         # to act on yet: report wait, so --watch holds through the parked
         # state and returns on the first real event instead of answering
         # "ready" on every poll (#228). Only a settled draft is actionable,
         # and that action belongs to the operator: mark it ready.
         elif $s.draft then
           # checks_settled is deliberately NOT the gate here: it demands at
           # least one registered context and zero undispatched required ones,
           # which a draft often cannot satisfy — workflows that skip drafts
           # or trigger on ready_for_review leave contexts unregistered, and a
           # fork draft has runs sitting unapproved. Holding the watch on
           # those waits for an event that only readying can produce. So only
           # checks actually RUNNING hold the wait; everything else is the
           # operator call this state exists for: mark it ready.
           (if ($s.checks.pending > 0) then
              {action:"wait", why:"draft — \($s.checks.pending) check(s) still running"}
            # A not-started row whose run is still going, though no pending
            # row is visible: running too, so not ready yet.
            elif ($s.checks.not_started_busy_runs|length) > 0 then
              {action:"wait", why:"draft — a run is still going"}
            else
              {action:"ready",
               why:("draft — nothing running, mark ready when the work is done"
                    + (if ($s.undispatched|length) > 0
                       then " (\($s.undispatched|length) required context(s) not reported — dispatch happens on ready, or the runs await approval)"
                       else "" end)),
               cmd:"gh pr ready \($s.number) --repo \($s.repo)"}
            end)
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
         # Runs awaiting maintainer approval outrank every review and
         # signature branch below, because none of those can unblock the PR:
         # the required contexts have not started and will not start until
         # someone presses approve. Reported as `0 pending` before, since an
         # unapproved run produces no check run — so the ladder reached
         # request-review and named an action that could not help, which is
         # the failure mode this tool exists to prevent (#310, observed on
         # netresearch/simple-ldap-go#227: 29 check runs before a force-push,
         # 6 after, eight runs waiting).
         elif (($s.awaiting_approval|length) > 0) then
           {action:"approve-workflow-runs",
            why:("\($s.awaiting_approval|length) workflow run(s) on \($s.headOid[0:8]) await maintainer approval"
                 + " — \([$s.awaiting_approval[].name]|unique|join(", "))."
                 + " This is a fork pull request, and GitHub demands that approval after every new SHA."
                 + " Until then those runs report nothing at all, so the check counts above understate the gate"),
            cmd:([$s.awaiting_approval[] | "gh api -X POST repos/\($s.repo)/actions/runs/\(.id)/approve"] | join(" ; "))}
         # The signature requirement is READ here, not guessed, so none of the
         # guards of the rung below apply: no review and no further CI result
         # can lift it. Without this rung a review action outranked it whenever
         # one of those guards failed, and nothing named the signatures
         # (netresearch-branding-skill#110: BLOCKED, Copilot out of quota, 6 of
         # 29 commits unsigned under classic required_signatures, a required
         # context not yet reported — NEXT said only request-review). The
         # review state is carried along: it is a second gate, not a lesser one.
         elif (($s.unsigned|length) > 0 and $s.mergeState == "BLOCKED"
               and ($sig_required_by|length) > 0) then
           {action:"fix-signatures",
            why:("\($s.unsigned|length) commit(s) on this branch carry no valid signature — \($s.unsigned|join(", "))"
                 + " — and \($sig_required_by|join(" and "))"
                 + (if ($sig_required_by|length) > 1 then " require" else " requires" end)
                 + " signed commits, so the"
                 + " merge stays BLOCKED whatever the review state"
                 + (if ($s.reviewDecision | IN("REVIEW_REQUIRED", "CHANGES_REQUESTED"))
                    then ". The review gate is open as well (decision \($s.reviewDecision)); it does not lift this one"
                    elif ($s.has_review_on_head | not)
                    then ". The review gate is open as well (\($no_review)); it does not lift this one"
                    else "" end)
                 + ". Note: gh pr update-branch re-writes the head UNSIGNED"
                 + (if $branch_has_merges
                    then "; this branch contains merge commits (or more than one page of"
                         + " commits), which a linear rebase drops with any conflict resolution"
                         + " they carry — re-sign it with the tree-preserving procedure in"
                         + " references/pull-request-workflow.md § Re-signing a contributor's"
                         + " unsigned commits"
                    else "" end))}
           + (if $branch_has_merges then {}
              else {cmd:"git rebase --exec \"git commit --amend --no-edit -S\" $(git merge-base HEAD origin/\($s.base)) ; git push --force-with-lease"} end)
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
            cmd:"git rebase --exec \"git commit --amend --no-edit -S\" $(git merge-base HEAD origin/\($s.base)) ; git push --force-with-lease"}
         # An approval that does not count: classic protection with
         # require_last_push_approval discounts an approval from whoever
         # pushed last, so reviewDecision sits at REVIEW_REQUIRED with an
         # APPROVED row on the head and nothing visible names the reason
         # (go-cron#399: this gate surfaced only after every other gate was
         # green, because it lives in the admin-only classic endpoint the
         # rules query cannot see). classic_protection is null for
         # non-admin callers, so the branch never fires on guesswork. The
         # ruleset form of the same gate is a parameter of the pull_request
         # rule and is always readable (ldap-manager#690, 2026-09-30: an
         # APPROVED row, REVIEW_REQUIRED and "cause NOT determined" until the
         # require_last_push_approval of the ruleset was switched off; the
         # approver was the account that had pushed the rebased commits).
         elif ((($s.classic_protection != null and $s.classic_protection.last_push_approval)
                or ($s.last_push_rulesets | length) > 0)
               and $s.reviewDecision == "REVIEW_REQUIRED"
               and $s.has_review_on_head
               and ([$s.reviews_on_head[] | select(test("APPROVED"))] | length) > 0) then
           {action:"request-review",
            why:(([(if ($s.classic_protection != null and $s.classic_protection.last_push_approval)
                    then "classic branch protection" else empty end),
                   ($s.last_push_rulesets[] | "ruleset \(.)")]) as $sources
                 | ($sources | join(" and "))
                   + (if ($sources | length) > 1 then " set" else " sets" end)
                 + " require_last_push_approval — the APPROVED on \($s.headOid[0:8]) does not count if the approver made the most recent push. Someone OTHER than the last pusher must approve; alternatively the author pushes again and a previous approver re-approves")}
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
         # $no_current_approval gates this branch and the two below it for the
         # same reason the generic gate at the bottom tests has_review_on_head:
         # the demand is the never-merge-unreviewed POLICY, as the ruleset
         # branch says in its own why-text, and an APPROVED review on this head
         # satisfies it. Without the guard a PR that github-actions has already
         # approved still reports request-review, and pr-merge.sh
         # --self-reviewed then writes "the review this pull request demands is
         # unsatisfiable" into permanent PR history — a claim that is false
         # while the approval sits on the same SHA (#214).
         #
         # Not has_review_on_head: that is true for any non-author review
         # including a COMMENTED one, and the Copilot error rows ARE COMMENTED,
         # so testing it would let a failed bot review satisfy the policy. The
         # approval list is the one predicate an error row cannot answer.
         elif ($needs_copilot and $s.copilot_review_errored
               and $no_current_approval
               and ($s.has_copilot_review_on_head | not)
               and ($self_attested | not)
               and (($s.requested_reviewers|map(test("copilot";"i"))|any) | not)) then
           (if $s.copilot_quota_exhausted then
             # Quota, not outage: the quota limit is named — by this PR or by
             # the marker an earlier run left. Said once, with the fact that
             # makes retrying pointless: the quota is monthly and will NOT
             # recover this month, on this or any other PR. No cmd on purpose,
             # there is nothing to run.
             {action:"request-review",
              why:($unreviewed + $quota_why + $stale_approval),
              reason:"bot-review-unsatisfiable"}
            elif $copilot_exhausted then
             {action:"request-review",
              why:($unreviewed
                   + "Copilot failed \($s.copilot_error_count)x on \($s.headOid[0:8]), so the COMMENTED rows"
                   + " carry an error in the body rather than a review. Do not keep"
                   + " re-requesting: an outage may clear, a quota ceiling does not clear by"
                   + " asking. Review the diff yourself, say in the PR that the bot review was"
                   + " unavailable, and decide on that. This stays request-review because the"
                   + " ruleset still has no bot review — the tool cannot see that you read the"
                   + " diff\($stale_approval)"),
              reason:"bot-review-unsatisfiable"}
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
               and $no_current_approval
               and ($s.requested_reviewers|map(test("copilot";"i"))|any)) then
           {action:"await-review", why:"Copilot review already requested for \($s.headOid[0:8]) and not delivered yet — waiting, not re-requesting"}
         elif ($needs_copilot and ($s.has_copilot_review_on_head|not)
               and $no_current_approval
               and ($self_attested|not)) then
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
               why:($unreviewed + $quota_why + $stale_approval),
              reason:"bot-review-unsatisfiable"}
            else
              # The ruleset asks for a Copilot review and the merge does not
              # hang on it: a Copilot review counts toward no required
              # approval. What is being enforced is the never-merge-unreviewed
              # policy, and a review the author writes satisfies that policy
              # too — so this stamps the same reason the generic branch does.
              # "a review you write yourself" is two different commands
              # depending on who authored the pull request: the attestation is
              # the author to post, and pr-merge.sh --self-reviewed refuses
              # anyone else, so a non-author gets the ordinary approval instead —
              # unless they wrote commits here, or that is unknown ($approve_withheld).
              {action:"request-review", why:("copilot_code_review ruleset is active and Copilot has not reviewed \($s.headOid[0:8]) — the rule itself does not block the merge, since a Copilot review does not count toward required approvals; the demand here is the never-merge-unreviewed policy, not a host gate"
                    + (if $s.viewer == "" then " (the account this run is authenticated as is unknown: the response named no viewer; check gh auth status)" else "" end)
                    + (if $approve_withheld then "." + $co_author_why
                       else ", and a review you write yourself satisfies it: " end)
                    + (if $approve_withheld then ""
                       elif $s.attestation_available then "pr-merge.sh --self-reviewed"
                       else "gh pr review \($s.number) --repo \($s.repo) --approve, because the attestation belongs to the author (\($author)) and pr-merge.sh --self-reviewed refuses every other authenticated user"
                       end)
                    + (if $s.checks_settled then "" else " (CI is NOT settled yet: \($s.checks.pending) pending, \($s.undispatched|length) required context(s) not reported"
                                 + (if ($s.checks.not_started_busy_runs|length) > 0
                                    then ", run(s) \($s.checks.not_started_busy_runs|map(tostring)|join(", ")) still going" else "" end)
                                 + " — do not enqueue on this reading)" end)),
               reason:"review-required",
               cmd:"gh api repos/\($s.repo)/pulls/\($s.number)/requested_reviewers -X POST -f \"reviewers[]=copilot-pull-request-reviewer[bot]\""}
            end)
         elif (($s.has_review_on_head|not) and ($self_attested|not)) then
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
                why:($unreviewed + $quota_why + $stale_approval),
              reason:"bot-review-unsatisfiable"}
             elif $copilot_exhausted then
               {action:"request-review",
                why:("\($no_review). "
                     + "Copilot failed \($s.copilot_error_count)x on it, so its rows carry an error"
                     + " rather than a review. Do not keep re-requesting: an outage may clear, a"
                     + " quota ceiling does not clear by asking. Review the diff yourself and"
                     + " decide on that\($stale_approval)"),
                reason:"bot-review-unsatisfiable"}
              else
               # No bot review is in flight and none is required here, so what
               # is missing is A review rather than one from THAT bot. The reason is
               # stamped so `pr-merge.sh --self-reviewed` can post the
               # attestation and merge on it; requesting Copilot stays offered
               # as the other way to satisfy the same demand.
               {action:"request-review",
                why:(if $s.attestation_available
                     then $no_review + " — a review is required and the one you write yourself counts:"
                          + " read the diff, say in the pull request what you checked, and merge on that"
                          + " with pr-merge.sh --self-reviewed. Requesting Copilot below is the other way"
                          + " to satisfy the same demand, and commits you to waiting for its answer\($stale_approval)"
                     else $no_review + " — a review is required. The self-review attestation is an"
                          + " assertion by the author (\($author)), and pr-merge.sh --self-reviewed refuses"
                          + " every other account"
                          + (if $s.viewer == "" then "; the account this run is authenticated as is unknown"
                                  + " (the response named no viewer; check gh auth status)."
                             else "." end)
                          + (if $approve_withheld then $co_author_why
                             else " Review the diff and approve it as yourself: gh pr review"
                                  + " \($s.number) --repo \($s.repo) --approve" end)
                          + ". Requesting Copilot below is the other way to satisfy the same demand\($stale_approval)"
                     end),
                reason:"review-required",
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
           {action:"wait",
            why:("required check(s) still pending: \($s.checks.pending_required|join(", "))"
                 + (if ($s.checks.failing_other|length) > 0
                    then " — non-required red meanwhile: \($s.checks.failing_other|join(", ")); it decides nothing until the required ones conclude"
                    else "" end))}
         # Every failure rung above sits higher than merge; the not-started
         # fall-through is the one path that can arrive here with a red row.
         # GitHub does not report CLEAN with a red row, so this only guards an
         # inconsistent reading, but it keeps "no red row reaches merge" true.
         elif $s.mergeState == "CLEAN" and ($s.checks.failing|length) > 0 then
           {action:"wait", why:"mergeState CLEAN while \($s.checks.failing|length) row(s) are red — not merging on that reading"}
         elif ($s.mergeState == "CLEAN"
               and ($s.merge_methods|index("merge")|not)
               and ($s.merge_methods|index("rebase")|not)) then
           {action:"blocked",
            why:"clean, but this repo allows only squash — policy forbids squash, so enable merge or rebase first"}
         elif $s.mergeState == "CLEAN" then
           ({action:"merge",
             # The attestation is named on the way OUT, not silently consumed:
             # the operator reading NEXT=merge must see which review gate it
             # rests on, and where the record sits.
             # Two different honourings, named apart: a bot review that cannot
             # arrive, and a review that simply was the authors own. Saying the
             # first where the second is true writes a false claim of an
             # unsatisfiable bot into permanent pull-request history.
             why:(if $self_attested
                  then ("clean; the review gate rests on the Self-review attestation"
                        + " for \($s.headOid[0:8]) posted by the PR author"
                        + (if $s.self_review_url != null then " (\($s.self_review_url))" else "" end)
                        + (if ($s.copilot_quota_exhausted or $copilot_exhausted)
                           then " — honoured because the demanded bot review is unsatisfiable"
                                + " (quota wall or repeated failures on this head)"
                           else " — honoured because a review is required and no bot review was in flight"
                           end))
                  else "clean" end),
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
         # The same while the only red rows are not-started ones whose run is
         # still going: nothing to triage yet, the note says what to re-run.
         elif ($s.mergeState == "UNSTABLE" and ($s.checks.not_started_busy_runs|length) > 0) then
           {action:"wait", why:"UNSTABLE while a run is still going"}
         elif $s.mergeState == "UNSTABLE" then
           {action:"triage-ci", why:"UNSTABLE: a non-required check is red; the gate stays shut until it is green or the PR is force-merged"}
         elif $s.checks.pending > 0 then
           {action:"wait", why:"\($s.checks.pending) check(s) still running (none of them required)"}
         # A not-started row whose run is still going, with no visible pending
         # row to wait on (the busy job lies beyond the 100 rollup contexts,
         # or only the check suite says so): still running, so wait here,
         # before the rungs below that assume nothing runs any more.
         elif ($s.checks.not_started_busy_runs|length) > 0 then
           {action:"wait", why:("a run is still going"
                                + (if ($s.undispatched|length) > 0
                                   then "; \($s.undispatched|length) required context(s) never reported: \($s.undispatched|join(", "))" else "" end))}
         # Checked last, because it only matters once everything visible is
         # green: an unsigned commit produces no red check and no rollup entry,
         # so it surfaces purely as BLOCKED and used to end here as
         # "investigate".
         elif (($s.unsigned|length) > 0 and (($ruletypes | index("required_signatures")) != null)) then
           {action:"fix-signatures",
            why:("\($s.unsigned|length) commit(s) on this branch carry no valid signature — \($s.unsigned|join(", "))"
                 + " — and the required_signatures ruleset is active. GitHub reports this"
                 + " only as mergeStateStatus \($s.mergeState), never as a failing check"),
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
            cmd:("gh run list --repo \($s.repo) --branch \($s.head) --json databaseId,status,name"
                 + " — then for each action_required id:"
                 + " gh api -X POST repos/\($s.repo)/actions/runs/ID/approve."
                 + " If none await approval, close+reopen the PR to re-fire the events")}
         # A required context satisfied only by a superseded run of its
         # workflow (see $stale_required). Directly above investigate, so it
         # replaces that verdict only when nothing else explains the state.
         # The re-trigger is inferred, not measured: what was measured is
         # that re-running the job inside the old run does not help, and that
         # dropping the context from the ruleset does.
         elif (($stale_required|length) > 0) then
           {action:"fix-required-context",
            why:("\($stale_required|length) required context(s) reported only by a SUPERSEDED workflow run — "
                 + ([$stale_required[]
                     | "\(.context): only in \(.workflow) run #\(.reported_in.run_number) (\(.reported_in.event)),"
                       + " while the newest run #\(.newest_run.run_number) (\(.newest_run.event)) of that workflow"
                       + " on this head has no check run of that name"] | join("; "))
                 + ". GitHub shows such a context as Expected and keeps the PR BLOCKED (inferred: it"
                 + " evaluates the newest run of the workflow, not the newest check run of that name)."
                 + " Re-running the job inside the old run does not clear it. Get a newer run that"
                 + " contains the job: close and reopen the PR, or push a new commit (inferred, not"
                 + " verified). Durable fix: require a check every run of the workflow reports (an"
                 + " aggregate gate job) instead of a job that is skipped on some events"),
            stale_contexts:$stale_required,
            cmd:"gh pr close \($s.number) --repo \($s.repo) && gh pr reopen \($s.number) --repo \($s.repo)"}
         # The end of the ladder: nothing this script decides on explains the
         # state. The sentence says so and claims nothing more; snapshot()
         # attaches next.evidence with what it could read, so the reader sees
         # what was ruled out instead of guessing a cause (t3x-nr-image-optimize#201).
         else
           {action:"investigate", why:"mergeState=\($s.mergeState) with no failing check, no open thread and no missing review. The cause is NOT determined; check branch protection manually"}
         end)
    # The not-started note, built in this one place for every rung that can
    # be reached while such rows are red (rerun-ci names them itself). Their
    # runs may still have a job going or may have concluded; name both kinds,
    # with the command only for runs that can be re-run now (gh run rerun
    # refuses a run in progress). A pending-only wait loses its "nothing has
    # failed", which is no longer true.
    | if (.next.action | IN("wait", "fix-ci", "triage-ci")) and ($s.checks.not_started|length) > 0 then
        ($s.checks.not_started_runs - $s.checks.not_started_busy_runs) as $idle
        | .next.why = ((.next.why | sub(" — nothing has failed$"; ""))
                       + " — not started (no runner acquired): \($s.checks.not_started|join(", ")); "
                       + ([ (if ($s.checks.not_started_busy_runs|length) > 0
                             then "re-run once run(s) \($s.checks.not_started_busy_runs|map(tostring)|join(", ")) have finished" else empty end),
                            (if ($idle|length) > 0
                             then "run(s) \($idle|map(tostring)|join(", ")) can be re-run now: "
                                  + ($idle|map("gh run rerun \(.) --repo \($s.repo) --failed")|join(" && "))
                             else empty end)
                          ] | join("; ")))
      else . end
    # Structural blockers named beside whatever rung won. A review action sits
    # above every CI rung, so on a BLOCKED pull request it used to be the only
    # thing said while a required context had never reported and CodeQL could
    # never report (netresearch-branding-skill#110). Rungs that are themselves
    # about the unreported contexts already name them.
    | if $s.mergeState == "BLOCKED"
         and (.next.action | IN("request-review", "await-review", "fix-signatures"))
         and ($s.undispatched|length) > 0 then
        .next.why += ". Also BLOCKED: \($s.undispatched|length) required context(s) never reported on"
                     + " \($s.headOid[0:8]) — \($s.undispatched|join(", "))"
      else . end
    | if $s.mergeState == "BLOCKED" and $codeql_fork_gap then
        .next.why += ". Also BLOCKED (inferred): this is a fork pull request, the code_scanning rule"
                     + " requires CodeQL results, and no CodeQL row exists on \($s.headOid[0:8]). If the"
                     + " repository runs CodeQL default setup (gh api repos/\($s.repo)/code-scanning/default-setup"
                     + " --jq .state answers configured), it never analyzes fork pull requests and that"
                     + " rule cannot be met here; an advanced-setup workflow may still be pending. See"
                     + " github-project references/merge-strategy.md § \"CodeQL default setup never"
                     + " analyzes fork PRs\" for the helper-PR workaround"
      else . end
