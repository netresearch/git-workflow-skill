#!/usr/bin/env bash
# repo-contribution-preflight.sh — what this repository expects, before the first artifact.
#
# A repository's binding rules are scattered: some in the README, some in
# contribution docs two links deep, some in issue and PR templates, in
# .gitattributes export rules, in the CI matrix, and in pinned tool versions.
# Each is one command; together they are fifteen, which is why they get skipped
# and then discovered afterwards — with three artifacts already public and a
# maintainer watching the retrofit.
#
# The README is checked, not skipped. A small repository often states the whole
# contract there — target branch, sign-off, the command CI runs — and never
# writes a CONTRIBUTING at all. This script therefore reports the README
# headings that carry rules, fence-aware, so a "# Contributing" line inside a
# fenced example is not mistaken for a section.
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

# --version answers "which copy am I running" without diffing installations.
# Two installations can declare the SAME number while shipping different
# scripts (netresearch/git-workflow-skill#209 measured exactly that, and the
# missing flag read as a missing feature for a dozen merges). So the resolved
# path is printed beside the version: the number says what the copy claims to
# be, the path says which file actually answered.
#
# The version is read from the SKILL.md NEXT TO the script, never from a
# checkout elsewhere -- a cached copy must report the number it was packaged
# with, or the answer is worse than none. \042 and \047 are the quote
# characters by octal code, so this awk program contains no quote of its own
# to terminate the single-quoted string it lives in.
skill_version() {
    local here skill v
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    skill="$here/../SKILL.md"
    v="unknown"
    if [ -f "$skill" ]; then
        v="$(awk '/^[ \t]*version:/ {
                 s = $0
                 sub(/^[ \t]*version:[ \t]*/, "", s)
                 gsub(/[\042\047]/, "", s)
                 gsub(/[ \t\r]+$/, "", s)
                 if (s != "") { print s; exit }
             }' "$skill" 2>/dev/null)" || v=""
        [ -n "$v" ] || v="unknown"
    fi
    printf '%s %s\n' "$(basename "${BASH_SOURCE[0]}")" "$v"
    printf 'path: %s/%s\n' "$here" "$(basename "${BASH_SOURCE[0]}")"
}

REPO="."
SECTION="all"

while [ $# -gt 0 ]; do
    case "$1" in
        --repo) REPO="${2:?--repo needs a directory}"; shift 2 ;;
        --section) SECTION="${2:?--section needs a name}"; shift 2 ;;
        --version) skill_version; exit 0 ;;
        -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/,""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
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
    # -iname rather than a fixed list: GitHub resolves these case-insensitively,
    # so a repository carrying contributing.md is not one carrying nothing. The
    # community-health set is here in full (SUPPORT, GOVERNANCE, SECURITY,
    # CODE_OF_CONDUCT) because each can carry a rule that decides whether a
    # contribution is accepted, and each is served from .github/ or docs/ just
    # as often as from the root.
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        # The name globs are deliberately broad, so the extension decides. Without
        # this, -iname SECURITY* claims .github/workflows/security.yml as a
        # community-health document -- found by running the section against this
        # repository, which has exactly that workflow. An extensionless
        # CONTRIBUTING or SECURITY is a real document and stays.
        case "${f##*/}" in
            *.md|*.markdown|*.rst|*.txt|*.adoc) ;;
            *.*) continue ;;
            *) ;;
        esac
        found=1
        printf '  %-34s %s lines\n' "${f#./}" "$(grep -c "" "$f")"
        # A short CONTRIBUTING is usually a signpost: surface what it points at.
        # shellcheck disable=SC2016  # backticks and $ are regex syntax here, not shell
        links=$(grep -oE '\[[^]]+\]\([^)]+\)|<https?://[^>]+>|`[^`]+\.(md|rst)`' "$f" 2>/dev/null)
        [ -n "$links" ] || continue
        printf '%s\n' "$links" | head -8 | sed 's/^/      -> /'
        n=$(printf '%s\n' "$links" | grep -c "")
        # Never truncate silently: a capped list reads as a complete one.
        [ "$n" -gt 8 ] && printf '      -> (%s more link(s) not shown — read the file)\n' "$((n - 8))"
    done < <(find . -maxdepth 3 \
                  \( -path ./.git -o -path ./node_modules -o -path ./vendor \) -prune -o \
                  -type f \( -iname 'CONTRIBUTING*' -o -iname 'CODE_OF_CONDUCT*' \
                             -o -iname 'SUPPORT*'    -o -iname 'GOVERNANCE*' \
                             -o -iname 'SECURITY*'   -o -iname 'AGENTS.md' \
                             -o -iname 'CLAUDE.md' \) -print 2>/dev/null | sort)
    if [ "$found" = 0 ]; then
        # Deliberately not "(none)". GitHub serves CONTRIBUTING, CODE_OF_CONDUCT,
        # SUPPORT, SECURITY and both template kinds from the OWNER's .github
        # repository whenever the repository itself has none, and those defaults
        # bind exactly like local ones. This script does not go to the network,
        # so it names the query rather than answering it: an unchecked fallback
        # must never be reported as an absence.
        printf '  none IN THIS REPOSITORY — the owner default may still supply them\n'
        owner=$(git remote get-url origin 2>/dev/null \
                | sed -E 's#^[^:]*://[^/]+/##; s#^[^:]*:##; s#/.*$##')
        if [ -n "$owner" ]; then
            printf '    -> gh api repos/%s/.github/contents --jq ".[].name"\n' "$owner"
        else
            printf '    -> gh api repos/<owner>/.github/contents --jq ".[].name"\n'
        fi
    fi
fi

# --- The README, which is where a small repository states the whole contract -
if want docs; then
    head_ "README sections that carry rules"
    found=0
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        # Fence-aware on purpose: a heading regex is blind to code blocks, and a
        # README demonstrating `## Contributing` inside a fenced example would
        # otherwise be reported as having that section. Handles ATX (#) and the
        # underline form used by RST and setext Markdown.
        hits=$(awk '
            function rulebearing(h) {
                return tolower(h) ~ /contribut|pull request|merge request|code of conduct|commit|sign|coding|style|standard|develop|hacking|test|build|releas|governance|support|securit|licen[cs]e|getting started|setup|workflow|branch|patch/
            }
            /^[ \t]*(```|~~~)/ { fence = !fence; prev = ""; next }
            fence { prev = $0; next }
            /^[ \t]*#{1,6}[ \t]+/ {
                h = $0
                sub(/^[ \t]*#+[ \t]+/, "", h)
                sub(/[ \t]*#*[ \t]*$/, "", h)
                if (rulebearing(h)) printf "    %5d  %s\n", NR, h
                prev = $0; next
            }
            /^[ \t]*[=~^*+#"-]{3,}[ \t]*$/ {
                if (prev ~ /[^ \t]/) {
                    h = prev
                    gsub(/^[ \t]+|[ \t]+$/, "", h)
                    if (rulebearing(h)) printf "    %5d  %s\n", NR - 1, h
                }
                prev = $0; next
            }
            { prev = $0 }
        ' "$f")
        [ -n "$hits" ] || continue
        found=1
        printf '  %s\n' "${f#./}"
        printf '%s\n' "$hits"
    done < <(find . -maxdepth 2 \
                  \( -path ./.git -o -path ./node_modules -o -path ./vendor \) -prune -o \
                  -type f -iname 'README*' -print 2>/dev/null | sort)
    if [ "$found" = 0 ]; then
        printf '  no rule-bearing headings in the README\n'
        printf '    -> absence of a heading is not absence of a rule: a short README\n'
        printf '       can state the target branch or the sign-off in running prose\n'
    fi
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
    # PULL_REQUEST_TEMPLATE has a DIRECTORY form for multiple templates, and
    # both template kinds are also honoured at the root and under docs/ — a
    # .github-only list reports "no template" for repositories that have one.
    for f in .github/ISSUE_TEMPLATE/*.yml .github/ISSUE_TEMPLATE/*.yaml \
             .github/ISSUE_TEMPLATE/*.md .github/PULL_REQUEST_TEMPLATE.md \
             .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE/* \
             .github/ISSUE_TEMPLATE.md .github/issue_template.md \
             ISSUE_TEMPLATE.md PULL_REQUEST_TEMPLATE.md pull_request_template.md \
             docs/ISSUE_TEMPLATE.md docs/PULL_REQUEST_TEMPLATE.md \
             docs/pull_request_template.md \
             .gitlab/issue_templates/* \
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
