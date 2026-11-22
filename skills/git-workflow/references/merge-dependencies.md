# MR/PR dependency safeguards

## Contents

- [Detect prerequisites](#detect-prerequisites-before-proposing-a-merge)
- [GitHub](#github-keep-the-existing-merge-gate)
- [GitLab](#gitlab-choose-a-capability-not-a-label)
- [Clearing the safeguard](#clearing-the-safeguard)

## Detect prerequisites before proposing a merge

During creation, review and merge preparation, inspect the description, linked
tickets, discussions and changed code for prerequisites, even when the user did
not explicitly ask about dependencies. Examples: an API introduced by another
change, a migration required first, or a lock that makes a later operation safe.
A link alone is not proof of dependency: verify the reason and direction.

Record each edge as **prerequisite URL -> dependent URL**, the failure avoided,
and the completion condition (merged into which target, released, or deployed).
Check current state and target branches; closed without merge is not complete,
and merge alone does not prove that a required package release or migration is
available. Detect cycles and missing access; do not guess either away.

Reuse an existing equivalent blocker rather than duplicate it. Read all pages
of discussions/dependencies. A 403/404 or incomplete response means unknown or
unsupported, not an empty dependency list. Re-read before acting.

Proactively propose the suitable safeguard, and apply it when the user's task
authorizes that specific MR/PR change. A read-only review only proposes it.
Do not silently change project settings, protections, targets or other authors'
branches; do not merge, enable auto-merge, or publish comments merely because
a skill recommends them. A skill update itself authorizes none of these actions.

## GitHub: keep the existing merge gate

Read the existing stack procedures in `references/pull-request-workflow.md`
before changing branch relationships. Distinguish a hand-built base-branch chain
from a repository's supported native stack; do not assume either enforces a
semantic prerequisite such as a release or deployment. Preserve the existing
branch-deletion precautions, current-head CI/review requirements and merge
authorization for every change included in a stack.

Prefer an existing repository dependency check that actually fails while the
prerequisite is unmet **and is required on the current target**. Read its
configuration and result rather than trusting a green optional job or a
`Depends on #123` sentence. A body link, label or ordinary issue comment is
documentation, not a merge block.

Without a suitable automated gate, propose keeping the PR Draft and documenting
the exact prerequisite. An unresolved review thread blocks merging only where
the applicable branch protection/ruleset requires conversation resolution;
verify that rule and use an actual review thread, not an issue comment.
Do not fabricate a code-line comment just to obtain a thread. Describe manual
guards as manual: authorized reviewers can resolve them or mark the PR ready.

If an automated dependency check is needed, propose a reviewed repository change,
not an ad-hoc privileged workflow. It must fail closed on unreadable prerequisites,
validate the required target/state, and refresh after prerequisite changes.
Do not run untrusted PR code with write credentials. Installing the workflow or
changing required checks needs authorization; checking or proposing does not.

**A stack across a fork.** An upstream PR cannot use a branch of a fork as its
base, so a dependent change from a fork targets the upstream default branch
and carries the prerequisite's commits. Say so in the first paragraph of the
description ("contains the two commits of #A; merge #A first"); that sentence
is documentation, so the guard above still applies. The push to the fork runs
CI on the combined commits, which is the test of the combination. After the
prerequisite merges, rebase onto the default branch: the diff shrinks to the
dependent PR's own commits. Seen on sebastianfeldmann/phpbu#406, which carried
the commits of sebastianfeldmann/phpbu#405.

After fulfillment, recheck the target, head SHA and all existing gates before
clearing only the authorized dependency guard. A passing `pr-status.sh` gate
does not independently prove that a semantic prerequisite has been fulfilled.

See [protected branches](https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/managing-protected-branches/about-protected-branches).

## GitLab: choose a capability, not a label

Check the instance edition/version, project merge settings and current MR
state. Native [MR dependencies](https://docs.gitlab.com/user/project/merge_requests/dependencies/)
require Premium/Ultimate; Netresearch CE must not be assumed to have them.

- Where native dependencies are available, use the supported dependency
  relation, then read it back and verify the prerequisite and dependent IDs.
  Do not confuse a Jira issue link or body text with that relation.
  Native dependencies enforce merge order only. If fulfillment requires a
  release or deployment after merge, retain a separate unresolved discussion
  with enforced resolution or a required CI gate until that condition is met,
  including on paid editions. Establish it before allowing auto-merge; a
  later manual verification cannot prevent an already-enabled automatic merge.
- On CE, propose an **unresolved resolvable MR discussion** naming the
  prerequisite URL, technical reason and exact resolution condition. Read
  `only_allow_merge_if_all_discussions_are_resolved` from the project first.
  Without that setting the discussion is a reminder, not an enforced merge gate.
  Recommend the setting if missing; changing it needs separate authorization.
- Create a discussion through `POST projects/:id/merge_requests/:iid/discussions`
  with a body, not a plain note via `/notes`. Read the returned discussion
  back: require `individual_note=false`, a note with `resolvable=true` and
  `resolved=false`. If the server does not supply a resolvable thread, stop
  and report that the guard is not established. Do not claim success from HTTP
  success alone.
- Verify project setting, unresolved thread and the MR's
  `blocking_discussions_resolved` together. `detailed_merge_status` can show
  `draft_status` while other blockers exist; it does not enumerate every gate.
  Draft is useful additional protection, not a dependency relationship.
- Stacked MRs can make incremental review easier when the dependent branch
  actually builds on the prerequisite branch. Verify installed support and
  branch relationship before proposing a stack; two MRs targeting `develop`
  are not a stack. A stack is not a substitute for the dependency gate:
  merging into a feature branch or retargeting can change what is protected.
  Do not rebase/retarget an author's branch without authorization.

Read-only preflight (set `GITLAB_HOST`, numeric project `P`, dependent IID `M`):

```bash
glab api "projects/$P" | jq '{only_allow_merge_if_all_discussions_are_resolved}'
glab api "projects/$P/merge_requests/$M" |
  jq '{state,draft,source_branch,target_branch,sha,detailed_merge_status,blocking_discussions_resolved}'
glab api --paginate "projects/$P/merge_requests/$M/discussions?per_page=100" |
  jq '.[] | {id,individual_note,notes:[.notes[] | {id,resolvable,resolved,body}]}'
```

## Clearing the safeguard

After the prerequisite satisfies the recorded condition, re-read both changes,
verify same-repository code prerequisites are present on the intended target
(account for squash/cherry-pick). For cross-repository, release or deployment
prerequisites, verify availability and the version/environment actually consumed
by the dependent change instead of Git ancestry. Update/rebase the dependent
branch only if authorized, and rerun relevant tests
and current-head review/CI gates. Resolve only the dependency thread the task
authorizes resolving, with linked evidence; never bulk-resolve unrelated reviews
or clear a blocker merely because the predecessor is closed. If the condition
is not verifiable, leave it blocked and say what is missing.

See [Discussions API](https://docs.gitlab.com/api/discussions/) and
[stacked MRs](https://docs.gitlab.com/user/project/merge_requests/reviews/stacked_merge_requests/).
