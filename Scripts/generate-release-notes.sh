#!/bin/bash

set -euo pipefail

tag="${1:?Usage: generate-release-notes.sh TAG OUTPUT [PREVIOUS_TAG]}"
output="${2:?Usage: generate-release-notes.sh TAG OUTPUT [PREVIOUS_TAG]}"
previous_tag="${3:-}"
repository="${GITHUB_REPOSITORY:-dreamwhite/Pawxy}"

git rev-parse --verify "${tag}^{commit}" >/dev/null

if [[ -z "$previous_tag" ]]; then
  previous_tag="$(git describe --tags --abbrev=0 "${tag}^" 2>/dev/null || true)"
fi

if [[ -n "$previous_tag" ]]; then
  git rev-parse --verify "${previous_tag}^{commit}" >/dev/null
  range="${previous_tag}..${tag}"
else
  range="$tag"
fi

temporary_directory="$(mktemp -d "${TMPDIR:-/tmp}/pawxy-release-notes.XXXXXX")"
trap 'rm -rf "$temporary_directory"' EXIT

categories=(features fixes performance improvements documentation tests maintenance other)
for category in "${categories[@]}"; do
  : > "$temporary_directory/$category"
done

while IFS=$'\t' read -r commit subject; do
  [[ -n "$commit" ]] || continue

  # The version bump is useful in history but not useful to people updating Pawxy.
  if [[ "$subject" == chore\(release\):\ prepare\ v* ]]; then
    continue
  fi

  case "$subject" in
    feat* ) category="features" ;;
    fix* ) category="fixes" ;;
    perf* ) category="performance" ;;
    refactor* ) category="improvements" ;;
    docs* ) category="documentation" ;;
    test* ) category="tests" ;;
    ci* | build* | chore* ) category="maintenance" ;;
    * ) category="other" ;;
  esac

  short_commit="${commit:0:7}"
  printf -- '- %s ([`%s`](https://github.com/%s/commit/%s))\n' \
    "$subject" "$short_commit" "$repository" "$commit" \
    >> "$temporary_directory/$category"
done < <(git log --no-merges --format='%H%x09%s' "$range")

write_section() {
  local title="$1"
  local file="$2"

  if [[ -s "$file" ]]; then
    printf '## %s\n\n' "$title" >> "$output"
    cat "$file" >> "$output"
    printf '\n' >> "$output"
  fi
}

version="${tag#v}"
printf '# Pawxy %s\n\n' "$version" > "$output"

write_section "Features" "$temporary_directory/features"
write_section "Fixes" "$temporary_directory/fixes"
write_section "Performance" "$temporary_directory/performance"
write_section "Improvements" "$temporary_directory/improvements"
write_section "Documentation" "$temporary_directory/documentation"
write_section "Tests" "$temporary_directory/tests"
write_section "Build and maintenance" "$temporary_directory/maintenance"
write_section "Other changes" "$temporary_directory/other"

if ! grep -q '^- ' "$output"; then
  printf 'No changes were recorded for this release.\n\n' >> "$output"
fi

if [[ -n "$previous_tag" ]]; then
  printf '**Full changelog:** [%s…%s](https://github.com/%s/compare/%s...%s)\n' \
    "$previous_tag" "$tag" "$repository" "$previous_tag" "$tag" >> "$output"
fi
