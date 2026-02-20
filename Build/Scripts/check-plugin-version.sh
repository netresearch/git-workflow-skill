#!/usr/bin/env bash
set -euo pipefail

# Validate .claude-plugin/plugin.json version matches semver tags at HEAD.
# Adapted from TYPO3 extension check-tag-version.sh pattern.

# Find semver tags at HEAD (with or without v prefix), normalize to bare version
TAGS=$(git tag --points-at HEAD | sed -nE 's/^v?([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' || true)
[[ -z "${TAGS}" ]] && exit 0

# Extract version from plugin.json
PLUGIN_VERSION=$(python3 -c "import json; print(json.load(open('.claude-plugin/plugin.json'))['version'])")

if [[ -z "${PLUGIN_VERSION}" ]]; then
    echo "ERROR: Could not extract version from .claude-plugin/plugin.json" >&2
    exit 1
fi

# Check if plugin version matches any of the tags at HEAD
if ! echo "${TAGS}" | grep -qFx "${PLUGIN_VERSION}"; then
    echo "ERROR: .claude-plugin/plugin.json version (${PLUGIN_VERSION}) does not match any semver tag at HEAD." >&2
    echo "Tags found at HEAD:" >&2
    echo "${TAGS}" >&2
    exit 1
fi
