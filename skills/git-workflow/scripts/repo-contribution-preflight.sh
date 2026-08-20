#!/usr/bin/env bash
# repo-contribution-preflight.sh — what this repository expects, before the first artifact.
#
# A repository's binding rules are rarely in its README. They sit in contribution
# docs two links deep, in issue and PR templates, in .gitattributes export rules,
# in the CI matrix, and in pinned tool versions. Each is one command; together they
# are fifteen, which is why they get skipped and then discovered afterwards — with
# three artifacts already public and a maintainer watching the retrofit.
#
# This returns all of it in one call. It reads; it changes nothing.
#
# Usage: repo-contribution-preflight.sh [--repo <dir>] [--section <name>]
#
#   --repo <dir>      repository to inspect (default: current directory)
#   --section <name>  one of: docs, templates, packaging, ci, tools
#
# Exit status is 0 whenever the repository could be read. Absence of a file is a
# finding, not an error — "no CONTRIBUTING" is the answer to the question asked.

set -uo pipefail

REPO="."
SECTION="all"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs a directory}"; shift 2 ;;
        --section) SECTION="${2:?--section needs a name}"; shift 2 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

cd "$REPO" || { echo "cannot enter $REPO" >&2; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repository: $REPO" >&2; exit 2; }

want() { [ "$SECTION" = "all" ] || [ "$SECTION" = "$1" ]; }
head_() { printf '\n=== %s ===\n' "$1"; }
none()  { printf '  (none)\n'; }

# --- Contribution docs, and the pages they link -----------------------------
if want docs; then
    head_ "Contribution docs"
    found=0
    for f in CONTRIBUTING.md CONTRIBUTING.rst CONTRIBUTING.txt AGENTS.md CLAUDE.md \
             .github/CONTRIBUTING.md docs/CONTRIBUTING.md CODE_OF_CONDUCT.md; do
        [ -f "$f" ] || continue
        found=1
        printf '  %-32s %s lines\n' "$f" "$(grep -c "" "$f")"
        # A short CONTRIBUTING is usually a signpost: surface what it points at.
        # shellcheck disable=SC2016  # backticks and $ are regex syntax here, not shell
        grep -oE '\[[^]]+\]\([^)]+\)|<https?://[^>]+>|`[^`]+\.(md|rst)`' "$f" 2>/dev/null \
            | head -8 | sed 's/^/      -> /'
    done
    [ "$found" = 1 ] || none
fi

# --- Issue and PR templates -------------------------------------------------
if want templates; then
    head_ "Issue / PR templates"
    found=0
    for f in .github/ISSUE_TEMPLATE/config.yml .github/ISSUE_TEMPLATE/config.yaml; do
        [ -f "$f" ] || continue
        found=1
        printf '  %s\n' "$f"
        # blank_issues_enabled: false means a template is mandatory.
        grep -E 'blank_issues_enabled' "$f" | sed 's/^/    /'
    done
    for f in .github/ISSUE_TEMPLATE/*.yml .github/ISSUE_TEMPLATE/*.yaml \
             .github/ISSUE_TEMPLATE/*.md .github/PULL_REQUEST_TEMPLATE.md \
             .github/pull_request_template.md .gitlab/issue_templates/* \
             .gitlab/merge_request_templates/*; do
        [ -f "$f" ] || continue
        case "$f" in */config.y*ml) continue ;; esac
        found=1
        printf '  %s\n' "$f"
    done
    [ "$found" = 1 ] || none
fi

# --- What a published package actually ships --------------------------------
if want packaging; then
    head_ "Packaging (what ships, what is a separate package)"

    # export-ignore decides whether tests/docs exist in the published artifact.
    found=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        ignored=$(grep -E 'export-ignore' "$f" | awk '{print $1}' | tr '\n' ' ')
        [ -n "$ignored" ] || continue
        found=1
        printf '  %-44s export-ignore: %s\n' "$f" "$ignored"
    done < <(printf '%s\n' .gitattributes packages/*/.gitattributes */.gitattributes 2>/dev/null)
    [ "$found" = 1 ] || printf '  no export-ignore rules\n'

    # Sub-splitting makes per-package metadata load-bearing rather than cosmetic.
    splits=""
    for f in .github/workflows/*split*; do
        [ -f "$f" ] && splits="$splits $f"
    done
    if [ -n "$splits" ]; then
        printf '  sub-split workflow present:%s\n' "$splits"
        printf '    -> each packages/* is published on its own; its composer.json is the contract\n'
    fi

    # An empty production autoload at the root makes root-level checks blind.
    if [ -f composer.json ] && command -v jq >/dev/null 2>&1; then
        root_autoload=$(jq -r 'if (.autoload | type) == "object" then "present" else "ABSENT" end' composer.json)
        printf '  root composer.json production autoload: %s\n' "$root_autoload"
        [ "$root_autoload" = "ABSENT" ] && \
            printf '    -> checks run at the root scan nothing; run them per package\n'
    fi
fi

# --- The matrix that actually runs ------------------------------------------
if want ci; then
    head_ "CI"
    found=0
    for f in .github/workflows/*.y*ml .gitlab-ci.yml Jenkinsfile .concourse/*.y*ml; do
        [ -f "$f" ] || continue
        found=1
        printf '  %s\n' "$f"
        if command -v yq >/dev/null 2>&1; then
            case "$f" in
              *.yml|*.yaml)
                # `//` not an if-expression: the go-yq lexer rejects inline `if` here.
                yq -r '(.jobs // {}) | to_entries[] | "    " + .key + " -> " + (.value.uses // "inline")' \
                    "$f" 2>/dev/null | head -12
                ;;
            esac
        fi
    done
    [ "$found" = 1 ] || none
    printf '\n  The matrix a reusable workflow expands to is only visible on a real run:\n'
    printf '    gh api "repos/<owner>/<repo>/commits/<sha>/check-runs?per_page=100" --jq ".check_runs[].name" | sort -u\n'
fi

# --- Pinned tool versions ---------------------------------------------------
if want tools; then
    head_ "Pinned tools"
    found=0
    if [ -f .phive/phars.xml ]; then
        found=1
        printf '  .phive/phars.xml\n'
        grep -oE 'name="[^"]+" version="[^"]+"( installed="[^"]+")?' .phive/phars.xml \
            | sed 's/^/    /'
        printf '    -> a pinned analyser can be older than the code it parses; an abort\n'
        printf '       can print nothing and read exactly like a clean run\n'
    fi
    for f in .tool-versions .php-version .nvmrc rust-toolchain.toml; do
        [ -f "$f" ] || continue
        found=1
        printf '  %-24s %s\n' "$f" "$(tr '\n' ' ' < "$f")"
    done
    [ "$found" = 1 ] || none
fi

printf '\n'
exit 0
