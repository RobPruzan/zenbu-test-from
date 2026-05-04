#!/usr/bin/env bash
set -euo pipefail

TRACKED_PATHS=(
  "packages/alpha/"
  "packages/beta/"
  "packages/gamma/"
)

WORKSPACE_CATALOG_FILE="pnpm-workspace.yaml"

usage() {
  echo "Usage: $0 --init|--sync --target-repo <url> [--source-repo <url>]"
  echo ""
  echo "Modes:"
  echo "  --init    One-time seed: extract full history via git-filter-repo and push to target"
  echo "  --sync    Incremental: replay new commits since last sync to target"
  echo ""
  echo "Options:"
  echo "  --target-repo   Git URL of the mirror repo to push to"
  echo "  --source-repo   Git URL of the source repo (only needed for --init)"
  exit 1
}

MODE=""
TARGET_REPO=""
SOURCE_REPO=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --init) MODE="init"; shift ;;
    --sync) MODE="sync"; shift ;;
    --target-repo) TARGET_REPO="$2"; shift 2 ;;
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

[[ -z "$MODE" ]] && usage
[[ -z "$TARGET_REPO" ]] && { echo "Error: --target-repo is required"; usage; }

generate_workspace_yaml() {
  local source_workspace="$1"
  local output_file="$2"

  echo "packages:" > "$output_file"
  echo "  - 'packages/*'" >> "$output_file"

  if grep -q "^catalog:" "$source_workspace" 2>/dev/null; then
    echo "" >> "$output_file"
    sed -n '/^catalog:/,/^[^ ]/{ /^catalog:/p; /^  /p; }' "$source_workspace" >> "$output_file"
  fi
}

generate_root_package_json() {
  local output_file="$1"
  cat > "$output_file" <<'PKGJSON'
{
  "name": "zenbu-ts",
  "private": true,
  "type": "module"
}
PKGJSON
}

generate_gitignore() {
  local output_file="$1"
  cat > "$output_file" <<'GITIGNORE'
node_modules/
dist/
.zenbu/
GITIGNORE
}

do_init() {
  [[ -z "$SOURCE_REPO" ]] && { echo "Error: --source-repo is required for --init"; exit 1; }

  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "$WORK_DIR"' EXIT

  echo "==> Cloning source repo into temp dir..."
  git clone "$SOURCE_REPO" "$WORK_DIR/source"
  cd "$WORK_DIR/source"

  SOURCE_HEAD=$(git rev-parse HEAD)
  echo "==> Source HEAD: $SOURCE_HEAD"

  echo "==> Running git-filter-repo to extract tracked paths..."
  FILTER_ARGS=()
  for path in "${TRACKED_PATHS[@]}"; do
    FILTER_ARGS+=(--path "$path")
  done
  FILTER_ARGS+=(--path "$WORKSPACE_CATALOG_FILE")

  git-filter-repo "${FILTER_ARGS[@]}" --force

  echo "==> Generating root config files..."
  generate_workspace_yaml "$WORKSPACE_CATALOG_FILE" "$WORKSPACE_CATALOG_FILE"
  generate_root_package_json "package.json"
  generate_gitignore ".gitignore"

  git add .
  git commit -m "$(printf 'chore: add generated root files\n\n[synced from %s]' "$SOURCE_HEAD")" --allow-empty || true

  echo "==> Pushing to target repo..."
  git remote add target "$TARGET_REPO" 2>/dev/null || git remote set-url target "$TARGET_REPO"
  git push --force target main

  echo "==> Init complete. Mirror seeded from source HEAD $SOURCE_HEAD"
}

do_sync() {
  SOURCE_DIR=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "Error: --sync must be run from within the source repo"
    exit 1
  }
  cd "$SOURCE_DIR"

  WORK_DIR=$(mktemp -d)
  trap 'rm -rf "$WORK_DIR"' EXIT

  echo "==> Cloning target repo..."
  git clone "$TARGET_REPO" "$WORK_DIR/target"

  LAST_SYNCED=$(git -C "$WORK_DIR/target" log -1 --format="%B" | grep -o '\[synced from [a-f0-9]*\]' | grep -o '[a-f0-9]\{40\}' || true)
  if [[ -z "$LAST_SYNCED" ]]; then
    echo "Error: target repo has no [synced from <sha>] marker in latest commit. Run --init first."
    exit 1
  fi
  echo "==> Last synced SHA: $LAST_SYNCED"

  CURRENT_HEAD=$(git rev-parse HEAD)
  if [[ "$LAST_SYNCED" == "$CURRENT_HEAD" ]]; then
    echo "==> Already up to date."
    exit 0
  fi

  COMMITS=$(git log --first-parent --reverse --format="%H" "$LAST_SYNCED".."$CURRENT_HEAD")
  if [[ -z "$COMMITS" ]]; then
    echo "==> No new commits to sync."
    exit 0
  fi

  COMMIT_COUNT=$(echo "$COMMITS" | wc -l | tr -d ' ')
  echo "==> Found $COMMIT_COUNT new commit(s) to process"

  SYNCED=0

  while IFS= read -r COMMIT_SHA; do
    CHANGED_FILES=$(git diff-tree --no-commit-id --name-only -r "$COMMIT_SHA" 2>/dev/null || true)

    TOUCHES_TRACKED=false
    for path in "${TRACKED_PATHS[@]}"; do
      if echo "$CHANGED_FILES" | grep -q "^${path}"; then
        TOUCHES_TRACKED=true
        break
      fi
    done

    TOUCHES_WORKSPACE=false
    if echo "$CHANGED_FILES" | grep -q "^${WORKSPACE_CATALOG_FILE}$"; then
      TOUCHES_WORKSPACE=true
    fi

    if [[ "$TOUCHES_TRACKED" == false && "$TOUCHES_WORKSPACE" == false ]]; then
      echo "    skip $COMMIT_SHA (no tracked paths changed)"
      continue
    fi

    COMMIT_MSG=$(git log -1 --format="%B" "$COMMIT_SHA")
    COMMIT_AUTHOR_NAME=$(git log -1 --format="%an" "$COMMIT_SHA")
    COMMIT_AUTHOR_EMAIL=$(git log -1 --format="%ae" "$COMMIT_SHA")
    COMMIT_DATE=$(git log -1 --format="%ai" "$COMMIT_SHA")

    echo "    sync $COMMIT_SHA: $(echo "$COMMIT_MSG" | head -1)"

    for path in "${TRACKED_PATHS[@]}"; do
      TARGET_PATH="$WORK_DIR/target/$path"
      rm -rf "$TARGET_PATH"

      if git -C "$SOURCE_DIR" show "$COMMIT_SHA:$path" > /dev/null 2>&1; then
        mkdir -p "$(dirname "$TARGET_PATH")"
        git -C "$SOURCE_DIR" archive "$COMMIT_SHA" -- "$path" | tar -x -C "$WORK_DIR/target/"
      fi
    done

    if [[ "$TOUCHES_WORKSPACE" == true ]]; then
      SOURCE_WORKSPACE_CONTENT=$(git -C "$SOURCE_DIR" show "$COMMIT_SHA:$WORKSPACE_CATALOG_FILE" 2>/dev/null || true)
      if [[ -n "$SOURCE_WORKSPACE_CONTENT" ]]; then
        TMP_WS=$(mktemp)
        echo "$SOURCE_WORKSPACE_CONTENT" > "$TMP_WS"
        generate_workspace_yaml "$TMP_WS" "$WORK_DIR/target/$WORKSPACE_CATALOG_FILE"
        rm -f "$TMP_WS"
      fi
    fi

    git -C "$WORK_DIR/target" add -A

    if git -C "$WORK_DIR/target" diff --cached --quiet; then
      echo "      (empty diff after filtering, skipping)"
      continue
    fi

    GIT_AUTHOR_NAME="$COMMIT_AUTHOR_NAME" \
    GIT_AUTHOR_EMAIL="$COMMIT_AUTHOR_EMAIL" \
    GIT_AUTHOR_DATE="$COMMIT_DATE" \
    GIT_COMMITTER_DATE="$COMMIT_DATE" \
    git -C "$WORK_DIR/target" commit -m "$(printf '%s\n\n[synced from %s]' "$COMMIT_MSG" "$COMMIT_SHA")"

    SYNCED=$((SYNCED + 1))
  done <<< "$COMMITS"

  if [[ $SYNCED -gt 0 ]]; then
    echo "==> Pushing $SYNCED synced commit(s) to target..."
    git -C "$WORK_DIR/target" push origin main
  else
    git -C "$WORK_DIR/target" commit --allow-empty \
      -m "$(printf 'chore: advance sync marker\n\n[synced from %s]' "$CURRENT_HEAD")"
    git -C "$WORK_DIR/target" push origin main
  fi

  echo "==> Sync complete. Processed $COMMIT_COUNT commit(s), synced $SYNCED."
}

case "$MODE" in
  init) do_init ;;
  sync) do_sync ;;
esac
