#!/usr/bin/env bash
# Collects city.json from every repo of $OWNER that publishes one to GitHub Pages, plus any extra
# URLs listed in $CC_CONFIG, then merges them into one personal city in $CC_OUT.
# Uses only the workflow's GITHUB_TOKEN (public listing), so no personal token is ever stored.
set -euo pipefail

: "${OWNER:?}" "${CC_OUT:?}" "${COMMITCITY_BIN:?}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/cities" "$CC_OUT"

declare -A excluded=()
urls=()
if [ -f "${CC_CONFIG:-}" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    key="$(printf '%s' "${line%%:*}" | tr -d '[:space:]')"
    value="$(printf '%s' "${line#*:}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$key" in
      include) urls+=("$value") ;;
      exclude) excluded["$value"]=1 ;;
      "") ;;
      *) echo "::warning::$CC_CONFIG: unknown key '$key'" ;;
    esac
  done < "$CC_CONFIG"
fi

# Public, non-fork repos with Pages enabled. Archived repos stay in: they are finished or decaying.
while IFS=$'\t' read -r repo has_pages; do
  [ -n "$repo" ] || continue
  [ -z "${excluded[$repo]:-}" ] || continue
  [ "$has_pages" = "true" ] || continue
  if [ "$repo" = "$OWNER.github.io" ]; then
    urls+=("https://$OWNER.github.io/city.json")
  else
    urls+=("https://$OWNER.github.io/$repo/city.json")
  fi
done < <(gh api --paginate "users/$OWNER/repos?type=owner&per_page=100" \
  --jq '.[] | select(.fork | not) | [.name, (.has_pages | tostring)] | @tsv')

count=0
for url in "${urls[@]}"; do
  count=$((count + 1))
  file="$work/cities/$count.json"
  # Pages may redirect to a custom domain; cap size and time so one bad host cannot stall the run.
  if curl -fsSL --proto '=https' --max-time 30 --max-filesize 50000000 -o "$file" "$url"; then
    echo "collected $url"
  else
    echo "::notice::no city at $url"
    rm -f "$file"
  fi
done

shopt -s nullglob
files=("$work"/cities/*.json)
if [ ${#files[@]} -eq 0 ]; then
  echo "::error::No city.json found. Add the Commit City action to at least one repo with Pages enabled."
  exit 1
fi

"$COMMITCITY_BIN" merge --out "$CC_OUT" --theme "${CC_THEME:-carbon}" --name "${CC_NAME:-$OWNER}" "${files[@]}"
cp "$GITHUB_ACTION_PATH/../viewer/index.html" "$CC_OUT/index.html"
