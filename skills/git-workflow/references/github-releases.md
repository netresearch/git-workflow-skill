# GitHub Releases

Release creation and management moved to the
[`github-release`](https://github.com/netresearch/github-release-skill) skill,
the canonical owner of this content. Invoke that skill for:

- GitHub Immutable Releases (deleted-tag reuse is permanently blocked)
- `--latest=false` for non-default-branch releases
- Multi-branch release sequencing and recovery after a failed publish

This skill (`git-workflow`) still owns the git side of a release — signed
commits, PR merge, and tagging conventions. See
`references/commit-conventions.md` and `references/pull-request-workflow.md`.
