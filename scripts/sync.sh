#!/usr/bin/env bash
set -euo pipefail

fail() {
  echo "::error::$1" >&2
  exit 1
}

require() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

require git
require gh
require jq

TARGET_OWNER="${INPUT_TARGET_OWNER:?target-owner is required}"
TARGET_REPO="${INPUT_TARGET_REPO:?target-repo is required}"
TARGET_BASE_BRANCH="${INPUT_TARGET_BASE_BRANCH:-main}"
SYNC_BRANCH="${INPUT_SYNC_BRANCH:-sync/from-legacy}"
SOURCE_PATH="${INPUT_SOURCE_PATH:-.}"
ALLOWED_DIFFERENCES="${INPUT_ALLOWED_DIFFERENCES:-.k8s/,charts/,.github/workflows/}"
PR_TITLE="${INPUT_PR_TITLE:-Sync from legacy}"
PR_LABEL="${INPUT_PR_LABEL:-sync-from-legacy}"
COMMIT_MESSAGE="${INPUT_COMMIT_MESSAGE:-Sync functional changes from legacy}"
FULL_SYNC="${INPUT_FULL_SYNC:-false}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"

[ -n "$TOKEN" ] || fail "GH_TOKEN or GITHUB_TOKEN must be set. Use a token with write access to ${TARGET_OWNER}/${TARGET_REPO}."
[ -d "$SOURCE_PATH/.git" ] || fail "source-path must point to a checked out git repository. Did you run actions/checkout first?"

SOURCE_REPOSITORY="${GITHUB_REPOSITORY:-$(git -C "$SOURCE_PATH" config --get remote.origin.url)}"
EVENT_NAME="${GITHUB_EVENT_NAME:-manual}"
EVENT_PATH="${GITHUB_EVENT_PATH:-}"
HEAD_SHA="${GITHUB_SHA:-$(git -C "$SOURCE_PATH" rev-parse HEAD)}"
BASE_SHA=""
ORIGIN_PR="manual"
ORIGIN_AUTHOR="${GITHUB_ACTOR:-unknown}"

if [ -n "$EVENT_PATH" ] && [ -f "$EVENT_PATH" ]; then
  case "$EVENT_NAME" in
    pull_request|pull_request_target)
      BASE_SHA="$(jq -r '.pull_request.base.sha // empty' "$EVENT_PATH")"
      HEAD_SHA="$(jq -r '.pull_request.merge_commit_sha // .pull_request.head.sha // empty' "$EVENT_PATH")"
      ORIGIN_PR="#$(jq -r '.pull_request.number // empty' "$EVENT_PATH")"
      ORIGIN_AUTHOR="$(jq -r '.pull_request.user.login // empty' "$EVENT_PATH")"
      ;;
    push)
      BASE_SHA="$(jq -r '.before // empty' "$EVENT_PATH")"
      HEAD_SHA="$(jq -r '.after // empty' "$EVENT_PATH")"
      ORIGIN_PR="push"
      ORIGIN_AUTHOR="$(jq -r '.sender.login // empty' "$EVENT_PATH")"
      ;;
  esac
fi

[ -n "$HEAD_SHA" ] && [ "$HEAD_SHA" != "null" ] || HEAD_SHA="$(git -C "$SOURCE_PATH" rev-parse HEAD)"
[ -n "$ORIGIN_AUTHOR" ] && [ "$ORIGIN_AUTHOR" != "null" ] || ORIGIN_AUTHOR="${GITHUB_ACTOR:-unknown}"

if [ -z "$BASE_SHA" ] || [ "$BASE_SHA" = "null" ] || [ "$BASE_SHA" = "0000000000000000000000000000000000000000" ]; then
  BASE_SHA="$(git -C "$SOURCE_PATH" rev-parse "$HEAD_SHA^" 2>/dev/null || git -C "$SOURCE_PATH" rev-list --max-parents=0 "$HEAD_SHA")"
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

CHANGED_FILES="$WORKDIR/changed-files.txt"
DELETED_FILES="$WORKDIR/deleted-files.txt"
FUNCTIONAL_CHANGED="$WORKDIR/functional-changed.txt"
FUNCTIONAL_DELETED="$WORKDIR/functional-deleted.txt"
COMMITS_FILE="$WORKDIR/commits.txt"
TARGET_DIR="$WORKDIR/target"

if [ "$FULL_SYNC" = "true" ]; then
  git -C "$SOURCE_PATH" ls-files > "$CHANGED_FILES"
  : > "$DELETED_FILES"
  git -C "$SOURCE_PATH" log -1 --format=%H "$HEAD_SHA" > "$COMMITS_FILE"
else
  git -C "$SOURCE_PATH" diff --name-only --diff-filter=ACMRT "$BASE_SHA..$HEAD_SHA" > "$CHANGED_FILES"
  git -C "$SOURCE_PATH" diff --name-only --diff-filter=D "$BASE_SHA..$HEAD_SHA" > "$DELETED_FILES"
  git -C "$SOURCE_PATH" log --format=%H "$BASE_SHA..$HEAD_SHA" > "$COMMITS_FILE"
fi

: > "$FUNCTIONAL_CHANGED"
: > "$FUNCTIONAL_DELETED"

is_allowed_difference() {
  local file="$1"
  local pattern
  IFS=',' read -ra patterns <<< "$ALLOWED_DIFFERENCES"
  for pattern in "${patterns[@]}"; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"
    pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [ -n "$pattern" ] || continue
    if [[ "$pattern" == */ ]]; then
      case "$file" in
        "$pattern"*) return 0 ;;
      esac
    elif [ "$file" = "$pattern" ]; then
      return 0
    fi
  done
  return 1
}

while IFS= read -r file; do
  [ -n "$file" ] || continue
  if ! is_allowed_difference "$file"; then
    echo "$file" >> "$FUNCTIONAL_CHANGED"
  fi
done < "$CHANGED_FILES"

while IFS= read -r file; do
  [ -n "$file" ] || continue
  if ! is_allowed_difference "$file"; then
    echo "$file" >> "$FUNCTIONAL_DELETED"
  fi
done < "$DELETED_FILES"

{
  echo "target-branch=$SYNC_BRANCH"
  if [ ! -s "$FUNCTIONAL_CHANGED" ] && [ ! -s "$FUNCTIONAL_DELETED" ]; then
    echo "sync-needed=false"
  else
    echo "sync-needed=true"
  fi
} >> "$GITHUB_OUTPUT"

if [ ! -s "$FUNCTIONAL_CHANGED" ] && [ ! -s "$FUNCTIONAL_DELETED" ]; then
  echo "No functional changes to sync."
  exit 0
fi

echo "Functional files to sync:"
cat "$FUNCTIONAL_CHANGED" "$FUNCTIONAL_DELETED"

export GH_TOKEN="$TOKEN"
gh auth setup-git
gh repo clone "$TARGET_OWNER/$TARGET_REPO" "$TARGET_DIR"
git -C "$TARGET_DIR" remote set-url origin "https://x-access-token:${TOKEN}@github.com/${TARGET_OWNER}/${TARGET_REPO}.git"

git -C "$TARGET_DIR" fetch origin "$SYNC_BRANCH" || true
if git -C "$TARGET_DIR" rev-parse --verify "origin/$SYNC_BRANCH" >/dev/null 2>&1; then
  git -C "$TARGET_DIR" checkout -B "$SYNC_BRANCH" "origin/$SYNC_BRANCH"
  git -C "$TARGET_DIR" rebase "origin/$TARGET_BASE_BRANCH"
else
  git -C "$TARGET_DIR" checkout -B "$SYNC_BRANCH" "origin/$TARGET_BASE_BRANCH"
fi

while IFS= read -r file; do
  [ -n "$file" ] || continue
  mkdir -p "$TARGET_DIR/$(dirname "$file")"
  cp "$SOURCE_PATH/$file" "$TARGET_DIR/$file"
done < "$FUNCTIONAL_CHANGED"

while IFS= read -r file; do
  [ -n "$file" ] || continue
  git -C "$TARGET_DIR" rm --ignore-unmatch "$file"
done < "$FUNCTIONAL_DELETED"

if git -C "$TARGET_DIR" diff --quiet; then
  echo "No diff after applying functional changes."
  echo "sync-needed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

git -C "$TARGET_DIR" config user.name "legacy-sync[bot]"
git -C "$TARGET_DIR" config user.email "legacy-sync[bot]@users.noreply.github.com"
git -C "$TARGET_DIR" add -A
git -C "$TARGET_DIR" commit -m "$COMMIT_MESSAGE"
git -C "$TARGET_DIR" push --set-upstream origin "$SYNC_BRANCH"

COMMITS="$(paste -sd ', ' "$COMMITS_FILE")"
BODY="$(cat <<EOF
## Sincronizacao do Repositorio Legacy

### Metadados de Origem
- Origem-Repo: ${SOURCE_REPOSITORY}
- Origem-Branch: ${GITHUB_REF_NAME:-main}
- Origem-PR: ${ORIGIN_PR}
- Origem-Commits: ${COMMITS}
- Origem-Autor: ${ORIGIN_AUTHOR}
- Destino-Repo: ${TARGET_OWNER}/${TARGET_REPO}

### Formato do Commit Squash
Ao dar merge com squash, use:

\`\`\`
Sincroniza alteracoes do legacy

Origem: ${SOURCE_REPOSITORY}
Origem-PR: ${ORIGIN_PR}
Origem-Commits: ${COMMITS}
Sincronizacao-PR: #PR_NUMBER
\`\`\`
EOF
)"

if [ -n "$PR_LABEL" ]; then
  gh label create "$PR_LABEL" --repo "$TARGET_OWNER/$TARGET_REPO" --color "0366d6" --description "Pull request sincronizado do repositorio legacy" --force
fi

EXISTING_PR="$(gh pr list --repo "$TARGET_OWNER/$TARGET_REPO" --head "$SYNC_BRANCH" --base "$TARGET_BASE_BRANCH" --state open --json number --jq '.[0].number // empty')"

if [ -n "$EXISTING_PR" ]; then
  gh pr edit "$EXISTING_PR" --repo "$TARGET_OWNER/$TARGET_REPO" --title "$PR_TITLE" --body "$BODY"
  if [ -n "$PR_LABEL" ]; then
    gh pr edit "$EXISTING_PR" --repo "$TARGET_OWNER/$TARGET_REPO" --add-label "$PR_LABEL"
  fi
  PR_URL="$(gh pr view "$EXISTING_PR" --repo "$TARGET_OWNER/$TARGET_REPO" --json url --jq '.url')"
else
  LABEL_ARGS=()
  if [ -n "$PR_LABEL" ]; then
    LABEL_ARGS=(--label "$PR_LABEL")
  fi
  PR_URL="$(gh pr create --repo "$TARGET_OWNER/$TARGET_REPO" --title "$PR_TITLE" --body "$BODY" --head "$SYNC_BRANCH" --base "$TARGET_BASE_BRANCH" "${LABEL_ARGS[@]}")"
fi

echo "pr-url=$PR_URL" >> "$GITHUB_OUTPUT"
echo "Sync PR: $PR_URL"
