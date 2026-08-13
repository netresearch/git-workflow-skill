# No editorializing — inform, don't sell (tone, not wordlist)

Applies to every written artifact: commit messages, PR/MR descriptions, review
comments, issue/ticket text, chat — and code comments, docstrings,
documentation, README and changelog files.

Editorializing is a matter of **tone and intent, not specific words** — no
banned-word list catches it, and the same word can be fine or not depending on
whether it carries a fact. The failure is writing about *how good, clean, or
careful the work is* instead of *what it does*. The reader has the diff and the
artifact; anything that only flatters the work or reassures them adds nothing,
and to a reviewer it reads as salesmanship — it provokes a counter-reaction
before they reach the substance.

Apply three tests before a sentence stays:

1. **Deletion** — remove the phrase. Did the reader lose a fact? If not, cut it.
2. **Subject** — is the sentence about the change, or about *you / your work*
   (its quality, your diligence)? The latter goes.
3. **Voice** — would a terse maintainer write this, or does it read like a
   cover letter?

Two recurring failure modes:

- **Announcing the expected.** Passing tests, clean linters, "documented", "no
  regressions", "works as expected" are the baseline — do not narrate them.
  State a check's status only to flag an *exception* (something knowingly
  failing or skipped). In a test/verification list, say what was *added or
  covered*, not that it is green.

- **Self-praise and reassurance.** Grading your own output ("clean", "robust",
  "elegant", "foolproof", "tidy", "genuinely new", "production-ready"); framings
  that reassure ("the honest breaking change", "deliberately scoped, not
  hidden", "where it belongs"); and the diligence humble-brag ("I carefully…",
  "I made sure to…", "thoroughly tested"). These describe the author, not the
  change. Show the fact; drop the framing. (The words are only symptoms — judge
  by the three tests above, not by the word.)

Use plain labels, not graded ones: "Breaking change", "Tests", "Limitations" —
not "Tests (all green)" or "Breaking change (honest)". If a limitation's cause
matters, it is already stated in the item.

## Line wrapping — GitHub comment surfaces vs `.md` files

Separate from tone: the artifacts above render through two different Markdown
pipelines, and hard-wrapping prose is right in one and wrong in the other.

- **`.md` files** (README, CHANGELOG, docs) render as CommonMark: a single
  newline inside a paragraph collapses to a **space**, so hard-wrapping the
  source at ~80 columns reflows invisibly on render. Match the file's existing
  wrap.
- **GitHub comment surfaces** — PR/MR descriptions, review comments, issue/ticket
  bodies, and **release notes** — render with `breaks: true`: every single
  newline becomes a `<br>`. Hard-wrapping there carries the breaks into the
  rendered page as ragged mid-sentence line breaks. Write each paragraph and list
  item as ONE long line; use blank lines only for real paragraph/item boundaries.

Do not wrap a release body or PR/comment the way you wrap a `.md` file. Fix one
already published with hard-wraps via `gh release edit <tag> --notes-file <file>`
(release bodies stay editable) or by editing the PR/comment.

### The rule breaks at the pipe, not at the keyboard

Knowing the rule is not enough, because the way it gets violated does not feel
like writing prose at all:

```bash
git log -1 --format=%b > /tmp/body.md
gh pr create --body-file /tmp/body.md      # <-- wrapped, every time
```

A commit body is *correctly* hard-wrapped at ~72 columns — `commit-conventions.md`
says so. Piping it into a PR body moves that text across the boundary this
section is about, and nothing in the command looks wrong. Observed on six of six
pull requests created that way in one session, while every body and comment the
same author typed by hand in the same session was clean: the rule was held for
writing and lost for plumbing.

The same applies to any other correctly-wrapped source: a CHANGELOG entry, an
ADR paragraph, a quoted issue body.

**Join the paragraphs before posting**, and strip the trailers while you are
there — a commit body carries `Signed-off-by`, which is noise in a PR
description:

```bash
git log -1 --format=%b \
  | sed '/^Signed-off-by:/d' \
  | awk 'BEGIN{RS="";ORS="\n\n"} {gsub(/\n/," "); gsub(/  +/," "); print}' > /tmp/body.md
```

That `awk` joins each blank-line-separated paragraph onto one line. It is
deliberately naive — it will also join a fenced code block or a list, so read
the result before posting rather than trusting it on a body that has either.

**The fingerprint.** `Signed-off-by:` visible in a rendered PR description means
that description came from a commit message, which means it is hard-wrapped.
Grep for it when auditing:

```bash
gh pr view "$PR" --repo "$R" --json body --jq .body | grep -c '^Signed-off-by:'
```
