#!/usr/bin/env bash
# Builds one district per public repo of $OWNER (its published city.json when it has one, otherwise
# generated here from a clone), adds any extra URLs listed in $CC_CONFIG, and merges them all into
# one personal city in $CC_OUT.
# Uses only the workflow's GITHUB_TOKEN (public listing), so no personal token is ever stored.
set -euo pipefail

: "${OWNER:?}" "${CC_OUT:?}" "${COMMITCITY_BIN:?}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/cities" "$work/repos" "$work/gen" "$CC_OUT"

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

# Every public, non-fork repo of $OWNER becomes a district automatically. A repo that already
# publishes its own city.json (the per-repo action) is taken as-is, so its .commitcity settings
# apply; any other repo is cloned and generated here. Archived repos stay in: they are finished
# or decaying. Private repos are not visible to GITHUB_TOKEN; list their city.json via `include:`.
count=0
fetch() { # url → next numbered file, or non-zero
  local file="$work/cities/$((count + 1)).json"
  # Pages may redirect to a custom domain; cap size and time so one bad host cannot stall the run.
  if curl -fsSL --proto '=https' --max-time 30 --max-filesize 50000000 -o "$file" "$1" 2>/dev/null; then
    count=$((count + 1))
    echo "collected $1"
  else
    rm -f "$file"
    return 1
  fi
}

while IFS=$'\t' read -r repo has_pages size_kb; do
  [ -n "$repo" ] || continue
  [ -z "${excluded[$repo]:-}" ] || continue
  # The profile repo is the city's own scaffolding, not a project.
  [ "$OWNER/$repo" != "${GITHUB_REPOSITORY:-}" ] || continue
  if [ "$has_pages" = "true" ]; then
    if [ "$repo" = "$OWNER.github.io" ]; then url="https://$OWNER.github.io/city.json"; else url="https://$OWNER.github.io/$repo/city.json"; fi
    fetch "$url" && continue
  fi
  if [ "$size_kb" -gt "${CC_MAX_REPO_KB:-2000000}" ]; then
    echo "::notice::skipping $repo: too large to clone here (${size_kb} KB). Add the per-repo action to it instead."
    continue
  fi
  clone="$work/repos/$repo.git"
  # Full history is needed (numstat reads every diff), but no working tree.
  if ! timeout 600 git clone --quiet --bare "https://github.com/$OWNER/$repo.git" "$clone" 2>/dev/null; then
    echo "::notice::skipping $repo: clone failed"
    continue
  fi
  if ! git --git-dir="$clone" rev-parse --verify --quiet HEAD >/dev/null; then
    echo "::notice::skipping $repo: no commits yet"
    rm -rf "$clone"
    continue
  fi
  if "$COMMITCITY_BIN" generate --repo "$clone" --out "$work/gen/$repo" --name "$repo" --theme "${CC_THEME:-carbon}" >/dev/null; then
    count=$((count + 1))
    cp "$work/gen/$repo/city.json" "$work/cities/$count.json"
    echo "generated $repo"
  else
    echo "::notice::skipping $repo: generate failed"
  fi
  rm -rf "$clone"
done < <(gh api --paginate "users/$OWNER/repos?type=owner&per_page=100" \
  --jq '.[] | select(.fork | not) | select(.private | not) | [.name, (.has_pages | tostring), (.size | tostring)] | @tsv')

for url in "${urls[@]}"; do
  fetch "$url" || echo "::notice::no city at $url"
done

shopt -s nullglob
files=("$work"/cities/*.json)
if [ ${#files[@]} -eq 0 ]; then
  echo "::error::No districts: $OWNER has no public repositories with commits."
  exit 1
fi

"$COMMITCITY_BIN" merge --out "$CC_OUT" --theme "${CC_THEME:-carbon}" --name "${CC_NAME:-$OWNER}" "${files[@]}"
cp "$GITHUB_ACTION_PATH/../viewer/index.html" "$CC_OUT/index.html"
