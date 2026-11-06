#!/usr/bin/env bash
set -Eeuo pipefail

OWNER="${MIGRATION_REPO_OWNER:-modasrdorkhane11251-alt}"
REPO="${MIGRATION_REPO_NAME:-modasr-vps-migration}"
BRANCH="${MIGRATION_REPO_BRANCH:-main}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

if [[ -z "$GITHUB_TOKEN" ]]; then
  echo "Set GITHUB_TOKEN to a fine-grained GitHub token with read:contents permission."
  exit 1
fi

if [[ -f migrate.sh ]]; then
  exec bash migrate.sh
fi

curl -fsSL \
  -H "Authorization: Bearer ${GITHUB_TOKEN}" \
  -H "Accept: application/vnd.github.raw" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  "https://api.github.com/repos/${OWNER}/${REPO}/contents/migrate.sh?ref=${BRANCH}" | bash
