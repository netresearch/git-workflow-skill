#!/usr/bin/env bash
# Regression test: repo-contribution-preflight.sh must find the rules where
# repositories actually put them.
#
# The script shipped answering only for CONTRIBUTING-style files in a fixed,
# case-sensitive list, and its own header said a repository's rules "are rarely
# in its README" — so a repository stating its whole contract in the README was
# reported as having no contribution docs at all.
#
# Builds throwaway git repositories; needs no network and no fixtures on disk.

set -euo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/skills/git-workflow/scripts/repo-contribution-preflight.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0

# A fresh repository per case: the script reads the working tree and a leftover
# file from a previous case would answer for the next one.
#
# mktemp, not a counter: this runs inside $(newrepo), so any variable it
# increments lives in the subshell and dies with it — a counter hands every case
# the SAME directory, and the assertions that only check for an ABSENCE then
# pass without ever exercising anything.
newrepo() {
    local r
    r="$(mktemp -d "$TMP/repo.XXXXXX")"
    git -C "$r" init -q
    git -C "$r" remote add origin "https://github.com/some-owner/some-repo.git"
    printf '%s\n' "$r"
}

run() { bash "$SCRIPT" --repo "$1" 2>&1; }

# The output is captured into a variable and matched from there — NEVER piped
# straight into `grep -q`. Under `set -o pipefail`, grep -q exits at the first
# match and closes the pipe, the script dies of SIGPIPE (141), and the pipeline
# reports failure BECAUSE the match succeeded. That inverts every assertion
# here: a found string reads as FAIL and a missing one as ok, which is the
# worst possible direction for a test to be wrong in.
says() { # says <name> <repo> <regex>   — output must match
    local out; out="$(run "$2")"
    if printf '%s\n' "$out" | grep -qE "$3"; then
        echo "  ok   $1"
    else
        echo "  FAIL $1: output does not match /$3/"
        fail=1
    fi
}

# Pulls ONE "=== <name> ===" block out of the report. Needed because `(none)`
# is a correct answer for the CI and template sections in most fixtures, so a
# grep over the whole output cannot say anything about the docs section alone.
section_of() { # section_of <repo> <section title>
    run "$1" | awk -v want="=== $2 ===" '
        $0 ~ /^=== / { inside = ($0 == want); next }
        inside { print }
    '
}

silent() { # silent <name> <repo> <regex> — output must NOT match
    local out; out="$(run "$2")"
    if printf '%s\n' "$out" | grep -qE "$3"; then
        echo "  FAIL $1: output unexpectedly matches /$3/"
        fail=1
    else
        echo "  ok   $1"
    fi
}

echo "case 1: rules live ONLY in the README — the sections must be reported"
R=$(newrepo)
cat > "$R/README.md" <<'MD'
# some-repo

A thing that does a thing.

## Contributing

Target the `develop` branch. Every commit needs a sign-off.

## Running the tests

    make test
MD
says "README Contributing heading found"   "$R" '^ +[0-9]+ +Contributing$'
says "README test heading found"           "$R" 'Running the tests'
# The absence claim is the dangerous half. `(none)` is a correct answer for the
# CI and template sections here, so this asserts against the docs block ALONE:
# it must not be a bare absence, and it must name what was not checked.
docs1="$(section_of "$R" "Contribution docs")"
if printf '%s\n' "$docs1" | grep -qE '^\s*\(none\)\s*$'; then
    echo "  FAIL contribution-docs block claims a bare (none)"
    fail=1
else
    echo "  ok   contribution-docs block avoids a bare (none)"
fi

echo "case 2: a heading inside a fenced block is an example, not a section"
R=$(newrepo)
cat > "$R/README.md" <<'MD'
# some-repo

Write your own README like this:

```markdown
## Contributing
Please sign your commits.
```

That is all.
MD
silent "fenced ## Contributing not reported" "$R" '[0-9]+ +Contributing'
says   "says no rule-bearing headings"       "$R" 'no rule-bearing headings'

echo "case 3: lowercase contributing.md — GitHub matches case-insensitively"
R=$(newrepo)
printf '# contributing\n\nRun make lint.\n' > "$R/contributing.md"
says "lowercase contributing.md found" "$R" 'contributing\.md +[0-9]+ lines'

echo "case 4: community-health files under .github/ and docs/"
R=$(newrepo)
mkdir -p "$R/.github" "$R/docs"
printf 'ask here\n'   > "$R/.github/SUPPORT.md"
printf 'we govern\n'  > "$R/docs/GOVERNANCE.md"
printf 'be nice\n'    > "$R/CODE_OF_CONDUCT.md"
says "SUPPORT.md under .github found"  "$R" '\.github/SUPPORT\.md'
says "GOVERNANCE.md under docs found"  "$R" 'docs/GOVERNANCE\.md'
says "CODE_OF_CONDUCT.md found"        "$R" 'CODE_OF_CONDUCT\.md'

echo "case 5: PULL_REQUEST_TEMPLATE as a DIRECTORY (multiple templates)"
R=$(newrepo)
mkdir -p "$R/.github/PULL_REQUEST_TEMPLATE"
printf 'bugfix\n'  > "$R/.github/PULL_REQUEST_TEMPLATE/bug.md"
printf 'feature\n' > "$R/.github/PULL_REQUEST_TEMPLATE/feature.md"
says "directory-form PR templates listed" "$R" 'PULL_REQUEST_TEMPLATE/bug\.md'

echo "case 6: no docs at all — must NOT claim absence, must name the org fallback"
R=$(newrepo)
printf 'nothing here\n' > "$R/notes.txt"
# GitHub serves the owner .github repository defaults when the repo has none,
# and this script never goes to the network — so it may only name the query.
says   "names the owner fallback repo" "$R" 'some-owner/\.github'
says   "prints a runnable query"       "$R" 'gh api repos/some-owner/\.github/contents'
# The point of the whole branch: with nothing found locally, the block must
# still not be the word "(none)" on its own, because the owner default was
# never consulted.
docs6="$(section_of "$R" "Contribution docs")"
if printf '%s\n' "$docs6" | grep -qE '^\s*\(none\)\s*$'; then
    echo "  FAIL contribution-docs block reports a bare (none) it did not verify"
    fail=1
else
    echo "  ok   unchecked owner fallback is not reported as an absence"
fi

echo "case 7: README.rst with underline headings"
R=$(newrepo)
cat > "$R/README.rst" <<'RST'
some-repo
=========

Prose.

Contributing
------------

Sign off every commit.
RST
says "RST underline heading found" "$R" '[0-9]+ +Contributing'

echo "case 8: a missing heading is not a missing rule — the caveat must be said"
R=$(newrepo)
printf 'Just a sentence, no headings at all.\n' > "$R/README.md"
says "warns that prose can still carry a rule" "$R" 'absence of a heading is not absence of a rule'

echo "case 9: --section docs still answers, other sections do not leak in"
R=$(newrepo)
printf '# some-repo\n\n## Contributing\n\nrules\n' > "$R/README.md"
sec_out="$(bash "$SCRIPT" --repo "$R" --section docs 2>&1)"
if printf '%s\n' "$sec_out" | grep -qE 'Contributing' \
   && ! printf '%s\n' "$sec_out" | grep -qE '^=== CI ==='; then
    echo "  ok   --section docs scopes correctly"
else
    echo "  FAIL --section docs did not scope correctly"
    fail=1
fi

echo "case 10: exit status stays 0 for a repository with nothing to report"
R=$(newrepo)
if bash "$SCRIPT" --repo "$R" >/dev/null 2>&1; then
    echo "  ok   empty repository exits 0"
else
    echo "  FAIL empty repository did not exit 0"
    fail=1
fi

# The name globs are broad by design, so nothing but the extension stops a CI
# workflow from being claimed as a community-health document. Found by running
# the section against the skill repository itself, which has security.yml --
# no fixture here had a workflow, so the suite was blind to it.
echo "case 12: .github/workflows/security.yml is a workflow, not a SECURITY doc"
R=$(newrepo)
mkdir -p "$R/.github/workflows"
printf 'name: security\non: push\n' > "$R/.github/workflows/security.yml"
docs12="$(section_of "$R" "Contribution docs")"
if printf '%s\n' "$docs12" | grep -qE 'workflows/security\.yml'; then
    echo "  FAIL a CI workflow was listed as a contribution document"
    fail=1
else
    echo "  ok   workflow not claimed as a contribution document"
fi

# The other direction, so the filter cannot be tightened into dropping real
# files: GitHub honours an extensionless CONTRIBUTING, and so must this.
echo "case 13: an extensionless CONTRIBUTING is still a document"
R=$(newrepo)
printf 'Target develop. Sign your commits.\n' > "$R/CONTRIBUTING"
says "extensionless CONTRIBUTING found" "$R" 'CONTRIBUTING +[0-9]+ lines'

echo "case 11: --help still prints the whole header, including the README note"
help_out="$(bash "$SCRIPT" --help 2>&1)"
if printf '%s\n' "$help_out" | grep -qE 'README is checked, not skipped'; then
    echo "  ok   --help covers the README behaviour"
else
    echo "  FAIL --help window no longer reaches the README note"
    fail=1
fi

if [ "$fail" -eq 0 ]; then
    echo "all pass"
else
    echo "FAILURES"
    exit 1
fi
