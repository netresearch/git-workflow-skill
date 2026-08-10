#!/bin/bash
# Git Workflow Verification Script
# Checks repository for git workflow best practices

set -e

REPO_DIR="${1:-.}"
ERRORS=0
WARNINGS=0

echo "=== Git Workflow Verification ==="
echo "Repository: $REPO_DIR"
echo ""

# Change to repo directory
cd "$REPO_DIR"

# Check if it's a git repository. Asking git, not testing for a `.git`
# directory: in a worktree `.git` is a *file* pointing at the real gitdir, so
# the directory test refused to run in every worktree — including the layout
# this skill's own references recommend.
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "❌ Not a git repository"
    exit 1
fi

# Check branch naming
echo "=== Branch Naming Convention ==="
BRANCHES=$(git branch -a 2>/dev/null | sed 's/^[* ]*//' | grep -v "HEAD" | sed 's/remotes\/origin\///' | sort -u)

VALID_PATTERN="^(main|master|develop|feature\/|fix\/|bugfix\/|hotfix\/|release\/|chore\/|docs\/|test\/|refactor\/)"
INVALID_BRANCHES=""

for branch in $BRANCHES; do
    if ! echo "$branch" | grep -qE "$VALID_PATTERN"; then
        INVALID_BRANCHES="$INVALID_BRANCHES $branch"
    fi
done

if [[ -n "$INVALID_BRANCHES" ]]; then
    echo "⚠️  Non-standard branch names found:"
    echo "  $INVALID_BRANCHES"
    echo "   Expected: main, develop, feature/*, fix/*, release/*, hotfix/*"
    WARNINGS=$((WARNINGS + 1))
else
    echo "✅ All branch names follow conventions"
fi

# Check commit message format
echo ""
echo "=== Commit Message Format ==="
RECENT_COMMITS=$(git log --oneline -20 2>/dev/null | head -20)

CONV_PATTERN="^[a-f0-9]+ (feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?(!)?: .+"
INVALID_COMMITS=0
VALID_COMMITS=0

while IFS= read -r commit; do
    if echo "$commit" | grep -qE "$CONV_PATTERN"; then
        VALID_COMMITS=$((VALID_COMMITS + 1))
    else
        # Allow merge commits
        if ! echo "$commit" | grep -qE "^[a-f0-9]+ Merge"; then
            INVALID_COMMITS=$((INVALID_COMMITS + 1))
        fi
    fi
done <<< "$RECENT_COMMITS"

TOTAL_COMMITS=$((VALID_COMMITS + INVALID_COMMITS))
if [[ $TOTAL_COMMITS -gt 0 ]]; then
    PERCENT=$((VALID_COMMITS * 100 / TOTAL_COMMITS))
    if [[ $PERCENT -ge 80 ]]; then
        echo "✅ $PERCENT% of commits follow Conventional Commits format"
    elif [[ $PERCENT -ge 50 ]]; then
        echo "⚠️  $PERCENT% of commits follow Conventional Commits format"
        WARNINGS=$((WARNINGS + 1))
    else
        echo "⚠️  Only $PERCENT% of commits follow Conventional Commits format"
        WARNINGS=$((WARNINGS + 1))
    fi
fi

# Check for .gitignore
echo ""
echo "=== .gitignore Check ==="
if [[ -f ".gitignore" ]]; then
    echo "✅ .gitignore exists"

    # Check for common patterns
    COMMON_IGNORES=("node_modules" ".env" "*.log" "dist" "build" ".DS_Store")
    MISSING_IGNORES=""

    for pattern in "${COMMON_IGNORES[@]}"; do
        if ! grep -q "$pattern" .gitignore 2>/dev/null; then
            MISSING_IGNORES="$MISSING_IGNORES $pattern"
        fi
    done

    if [[ -n "$MISSING_IGNORES" ]]; then
        echo "   ℹ️  Consider adding:$MISSING_IGNORES"
    fi
else
    echo "⚠️  No .gitignore file found"
    WARNINGS=$((WARNINGS + 1))
fi

# Check for hooks
echo ""
echo "=== Git Hooks ==="
if [[ -d ".git/hooks" ]]; then
    ACTIVE_HOOKS=$(find .git/hooks -type f ! -name "*.sample" 2>/dev/null | wc -l)
    if [[ $ACTIVE_HOOKS -gt 0 ]]; then
        echo "✅ Found $ACTIVE_HOOKS active hook(s)"
        find .git/hooks -type f ! -name "*.sample" -exec basename {} \; 2>/dev/null | sed 's/^/   /'
    else
        echo "ℹ️  No active git hooks"
    fi
fi

# Check for husky
if [[ -d ".husky" ]]; then
    echo "✅ Husky hooks directory found"
fi

# Check for commitlint
if [[ -f "commitlint.config.js" ]] || [[ -f ".commitlintrc" ]] || [[ -f ".commitlintrc.json" ]]; then
    echo "✅ Commitlint configuration found"
fi

# Check for branch protection (via CODEOWNERS)
echo ""
echo "=== Code Ownership ==="
if [[ -f "CODEOWNERS" ]] || [[ -f ".github/CODEOWNERS" ]] || [[ -f "docs/CODEOWNERS" ]]; then
    echo "✅ CODEOWNERS file found"
else
    echo "ℹ️  No CODEOWNERS file (optional)"
fi

# Check for PR template
echo ""
echo "=== PR Templates ==="
if [[ -f ".github/PULL_REQUEST_TEMPLATE.md" ]] || [[ -d ".github/PULL_REQUEST_TEMPLATE" ]]; then
    echo "✅ PR template(s) found"
else
    echo "ℹ️  No PR template (recommended)"
fi

# Check for CI/CD configuration
echo ""
echo "=== CI/CD Configuration ==="
CI_FOUND=false

if [[ -d ".github/workflows" ]]; then
    WORKFLOW_COUNT=$(find .github/workflows -name "*.yml" -o -name "*.yaml" 2>/dev/null | wc -l)
    if [[ $WORKFLOW_COUNT -gt 0 ]]; then
        echo "✅ GitHub Actions: $WORKFLOW_COUNT workflow(s)"
        CI_FOUND=true
    fi
fi

if [[ -f ".gitlab-ci.yml" ]]; then
    echo "✅ GitLab CI configuration found"
    CI_FOUND=true
fi

if [[ -f "Jenkinsfile" ]]; then
    echo "✅ Jenkinsfile found"
    CI_FOUND=true
fi

if [[ -f ".circleci/config.yml" ]]; then
    echo "✅ CircleCI configuration found"
    CI_FOUND=true
fi

if [[ -f "azure-pipelines.yml" ]]; then
    echo "✅ Azure Pipelines configuration found"
    CI_FOUND=true
fi

if [[ "$CI_FOUND" == "false" ]]; then
    echo "⚠️  No CI/CD configuration found"
    WARNINGS=$((WARNINGS + 1))
fi

# Check for semantic release
echo ""
echo "=== Release Configuration ==="
if [[ -f ".releaserc" ]] || [[ -f ".releaserc.json" ]] || [[ -f ".releaserc.yml" ]] || [[ -f "release.config.js" ]]; then
    echo "✅ Semantic release configuration found"
fi

# Check for CHANGELOG
if [[ -f "CHANGELOG.md" ]] || [[ -f "CHANGELOG" ]]; then
    echo "✅ CHANGELOG found"
else
    echo "ℹ️  No CHANGELOG (recommended for releases)"
fi

# Check for versioning
if [[ -f "package.json" ]]; then
    VERSION=$(grep '"version"' package.json | head -1 | sed 's/.*: *"\([^"]*\)".*/\1/')
    if [[ -n "$VERSION" ]]; then
        echo "✅ Package version: $VERSION"
    fi
fi

# Unreleased commits since the last tag. This was checkpoint GW-15, which the
# runner's allowlist rejected outright — a rev-range needs `<tag>..HEAD` and the
# count needs command substitution, and `..` and `$(` are both refused. It never
# ran once. Here a full shell is available, so the rule survives intact.
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null || true)
if [[ -n "$LAST_TAG" ]]; then
    UNRELEASED=$(git rev-list "${LAST_TAG}..HEAD" --count 2>/dev/null || echo 0)
    if [[ "$UNRELEASED" -le 20 ]]; then
        echo "✅ $UNRELEASED commit(s) since $LAST_TAG"
    else
        echo "⚠️  $UNRELEASED commits since $LAST_TAG — cut a release"
        WARNINGS=$((WARNINGS + 1))
    fi
else
    echo "ℹ️  No tags yet"
fi

# Check current branch
echo ""
echo "=== Current State ==="
CURRENT_BRANCH=$(git branch --show-current 2>/dev/null)
echo "Current branch: $CURRENT_BRANCH"

# Check for uncommitted changes
if git diff --quiet 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
    echo "✅ Working directory clean"
else
    CHANGES=$(git status --porcelain 2>/dev/null | wc -l)
    echo "⚠️  $CHANGES uncommitted change(s)"
fi

# Check if up to date with remote
if git remote | grep -q "origin" 2>/dev/null; then
    git fetch origin --quiet 2>/dev/null || true
    # --verify --quiet, because plain `git rev-parse origin/<branch>` echoes the
    # ref NAME back on stdout when it does not resolve. The literal string then
    # passed the -n test, the rev-list below failed on it, and `set -e` killed
    # the script three sections early — silently, on every unpushed branch.
    LOCAL=$(git rev-parse --verify --quiet "$CURRENT_BRANCH" || true)
    REMOTE=$(git rev-parse --verify --quiet "origin/$CURRENT_BRANCH" || true)

    if [[ -n "$LOCAL" && -n "$REMOTE" ]]; then
        if [[ "$LOCAL" == "$REMOTE" ]]; then
            echo "✅ Up to date with origin/$CURRENT_BRANCH"
        else
            BEHIND=$(git rev-list --count "$LOCAL..$REMOTE" 2>/dev/null || echo "?")
            AHEAD=$(git rev-list --count "$REMOTE..$LOCAL" 2>/dev/null || echo "?")
            echo "ℹ️  Branch is $AHEAD ahead, $BEHIND behind origin/$CURRENT_BRANCH"
        fi
    elif [[ -z "$REMOTE" ]]; then
        echo "ℹ️  Branch not pushed to origin yet"
    fi
fi

# Check for merge conflicts markers
echo ""
echo "=== Conflict Markers ==="
# Tracked files of ANY type: markers land in .md/.rst/.yaml just as often as in
# code, and an extension allow-list silently passes those. Anchored at line
# start, and WITHOUT a bare "=======" branch — that is an ordinary RST section
# underline and would report every docs tree as conflicted.
CONFLICT_FILES=$(git grep -lE '^(<<<<<<< |>>>>>>> )' -- . 2>/dev/null | head -5)
if [[ -z "$CONFLICT_FILES" ]] && ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    CONFLICT_FILES=$(grep -rlE '^(<<<<<<< |>>>>>>> )' . 2>/dev/null | grep -v node_modules | grep -v vendor | head -5)
fi
if [[ -n "$CONFLICT_FILES" ]]; then
    echo "❌ Conflict markers found in files:"
    while IFS= read -r conflict_file; do echo "   $conflict_file"; done <<< "$CONFLICT_FILES"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ No conflict markers found"
fi

echo ""
echo "=== Commit Signing ==="

# Read the signature from the commit object, not from `git log --show-signature`
# or `%G?`: those answer "can this machine verify it", and report a correctly
# signed commit as unsigned whenever gpg.format=ssh is set without
# gpg.ssh.allowedSignersFile. Same rule as checkpoint GW-17 and
# signing-preflight.sh. Cut at the first blank line so a `gpgsig` line in the
# message body cannot pass as a signature.
UNSIGNED=""
while read -r sha; do
    [[ -z "$sha" ]] && continue
    if ! git cat-file commit "$sha" 2>/dev/null | sed -n '/^$/q;p' | grep -qE '^gpgsig(-sha256)? '; then
        UNSIGNED="$UNSIGNED $sha"
    fi
done < <(git log -10 --format=%H 2>/dev/null)

if [[ -z "$UNSIGNED" ]]; then
    echo "✅ Last 10 commits all carry a signature"
else
    UNSIGNED_COUNT=$(wc -w <<< "$UNSIGNED")
    echo "⚠️  $UNSIGNED_COUNT of the last 10 commits carry no signature:"
    for sha in $UNSIGNED; do echo "   ${sha:0:8}"; done
    echo "   Signature presence only — whether a signature verifies is the host's"
    echo "   answer, not this check's. Probe your own setup with signing-preflight.sh."
    WARNINGS=$((WARNINGS + 1))
fi

# Summary
echo ""
echo "=== Summary ==="
echo "Errors: $ERRORS"
echo "Warnings: $WARNINGS"

if [[ $ERRORS -gt 0 ]]; then
    echo "❌ Verification FAILED"
    exit 1
elif [[ $WARNINGS -gt 3 ]]; then
    echo "⚠️  Verification completed with warnings"
    exit 0
else
    echo "✅ Verification PASSED"
    exit 0
fi
