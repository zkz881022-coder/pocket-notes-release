#!/usr/bin/env bash
set -euo pipefail

repo="${GITHUB_REPOSITORY:?Missing GitHub repository}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]
feed_dir="${1:?Missing snapshot directory}"
mkdir -p "$feed_dir"
main_sha="$(git ls-remote "https://github.com/$repo.git" refs/heads/main | cut -f1)"
[[ "$main_sha" =~ ^[0-9a-f]{40}$ ]]
curl --proto '=https' --fail --silent --show-error --max-time 30 --max-filesize 131072 \
    "https://raw.githubusercontent.com/$repo/$main_sha/public/feed.json" -o "$feed_dir/expected.json"
printf '%s\n' "$main_sha" > "$feed_dir/main-sha"
node -e '
  const assert = require("node:assert/strict");
  const repo = process.env.GITHUB_REPOSITORY;
  assert.equal(require("./mobile.json").feedUrl, "https://raw.githubusercontent.com/" + repo + "/main/public/feed.json");
'
printf 'Expected feed snapshot main:%s\n' "$main_sha"
