#!/usr/bin/env bash
# =============================================================================
# manifest.sh — repo-autopilot: Relevant Files Manifest Manager
#
# 스캔 결과에서 justfile 생성에 영향을 주는 파일 목록을 추출하고,
# git diff와 비교하여 파이프라인 실행 여부를 결정한다.
#
# Usage:
#   bash .autopilot/manifest.sh generate <scan-result.json>  → manifest.json 생성
#   bash .autopilot/manifest.sh check [base_ref]             → 변경 여부 확인 (exit code)
#
# Exit codes (check mode):
#   0 = 관련 파일 변경 있음 → 파이프라인 실행 필요
#   1 = 관련 파일 변경 없음 → 스킵 가능
#   2 = manifest 없음 → 첫 실행, 파이프라인 실행 필요
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST_FILE="${SCRIPT_DIR}/manifest.json"
ACTION="${1:-}"
TARGET_DIR="${SCRIPT_DIR}/.."

# grep 호환성
GREP_CMD="grep"
if command -v ggrep &>/dev/null; then
  GREP_CMD="ggrep"
fi

DEFAULT_EXCLUDES="node_modules .git __pycache__ .next venv .venv dist build .cache .autopilot .claude .idea .vscode"

build_exclude_opts() {
  local opts=""
  for dir in $DEFAULT_EXCLUDES; do
    opts="$opts --exclude-dir=$dir"
  done
  echo "$opts"
}

EXCLUDE_OPTS=$(build_exclude_opts)

safe_grep() {
  $GREP_CMD $EXCLUDE_OPTS "$@" 2>/dev/null || true
}

# =============================================================================
# generate: scan-result.json + 추가 탐색으로 관련 파일 매니페스트 생성
# =============================================================================
generate_manifest() {
  local scan_file="${2:-}"
  if [[ -z "$scan_file" || ! -f "$scan_file" ]]; then
    echo "❌ Usage: manifest.sh generate <scan-result.json>" >&2
    exit 1
  fi

  local files=()

  # 1) scan-result.json의 raw_matches에서 파일 경로 추출
  #    format: "path/to/file:linenum:content"
  while IFS= read -r line; do
    local filepath
    filepath=$(echo "$line" | sed 's/^\.\///' | cut -d: -f1)
    [[ -n "$filepath" && -f "$TARGET_DIR/$filepath" ]] && files+=("$filepath")
  done < <(jq -r '.raw_matches | to_entries[] | .value[]' "$scan_file" 2>/dev/null)

  # 2) 구조 파일 — 항상 추적 (존재하는 것만)
  local structure_files=(
    "package.json"
    "pyproject.toml"
    "requirements.txt"
    "requirements-dev.txt"
    "Pipfile"
    "Cargo.toml"
    "go.mod"
    "docker-compose.yml"
    "docker-compose.yaml"
    "compose.yml"
    "compose.yaml"
    "Dockerfile"
    "Makefile"
    "Taskfile.yml"
    "Taskfile.yaml"
    "Procfile"
    "fly.toml"
    "render.yaml"
    "railway.json"
    "vercel.json"
    "netlify.toml"
    "turbo.json"
    "nx.json"
    "pnpm-workspace.yaml"
    "lerna.json"
    ".env.example"
    ".env.template"
    "alembic.ini"
  )

  for f in "${structure_files[@]}"; do
    if [[ -f "$TARGET_DIR/$f" ]]; then
      files+=("$f")
    fi
  done

  # 3) 서브디렉터리의 package.json, pyproject.toml도 탐색 (1-depth)
  for subdir in "$TARGET_DIR"/*/; do
    [[ -d "$subdir" ]] || continue
    local dirname
    dirname=$(basename "$subdir")
    # 제외 디렉터리 스킵
    echo "$DEFAULT_EXCLUDES" | tr ' ' '\n' | $GREP_CMD -qx "$dirname" 2>/dev/null && continue

    for f in package.json pyproject.toml requirements.txt Dockerfile Makefile; do
      [[ -f "$subdir/$f" ]] && files+=("$dirname/$f")
    done
  done

  # 4) Dockerfile* 탐색 (멀티스테이지/서비스별)
  while IFS= read -r f; do
    local relpath
    relpath=$(echo "$f" | sed "s|^$TARGET_DIR/||")
    files+=("$relpath")
  done < <(find "$TARGET_DIR" -maxdepth 3 -name "Dockerfile*" -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/.autopilot/*" 2>/dev/null)

  # 5) grep 패턴 파일 — scanner가 검색하는 대상 패턴에 매칭되는 파일
  while IFS= read -r f; do
    local relpath
    relpath=$(echo "$f" | sed "s|^$TARGET_DIR/||;s|^\.\//||")
    files+=("$relpath")
  done < <(
    safe_grep -rl \
      -E '(uvicorn|gunicorn|flask run|next dev|next start|npm run dev|npm start|yarn dev|pnpm dev|cargo run|go run|deno run)' \
      --include="*.py" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
      --include="*.sh" --include="*.yml" --include="*.yaml" --include="*.toml" \
      "$TARGET_DIR"
  )

  # 중복 제거 + 정렬 → JSON
  local unique_files
  unique_files=$(printf '%s\n' "${files[@]}" | sort -u | jq -R '.' | jq -s '.')

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  jq -n \
    --arg timestamp "$timestamp" \
    --argjson files "$unique_files" \
    '{
      version: 1,
      generated_at: $timestamp,
      relevant_files: $files,
      total_count: ($files | length)
    }' > "$MANIFEST_FILE"

  echo "📋 Manifest generated: $(jq '.total_count' "$MANIFEST_FILE") files tracked" >&2
  cat "$MANIFEST_FILE"
}

# =============================================================================
# check: manifest.json과 git diff를 비교하여 파이프라인 실행 여부 결정
# =============================================================================
check_changes() {
  # manifest 없으면 첫 실행
  if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "📋 No manifest found — first run required" >&2
    exit 0  # 실행 필요
  fi

  local base_ref="${2:-HEAD~1}"

  # git diff에서 변경된 파일 목록
  local changed_files
  changed_files=$(cd "$TARGET_DIR" && git diff --name-only "$base_ref" HEAD 2>/dev/null || echo "")

  if [[ -z "$changed_files" ]]; then
    echo "📋 No git changes detected" >&2
    exit 1  # 스킵
  fi

  # manifest의 파일 목록과 교차 비교
  local manifest_files
  manifest_files=$(jq -r '.relevant_files[]' "$MANIFEST_FILE" 2>/dev/null)

  local matched=false

  while IFS= read -r changed; do
    [[ -z "$changed" ]] && continue

    # 1) manifest에 정확히 있는 파일
    if echo "$manifest_files" | $GREP_CMD -qxF "$changed" 2>/dev/null; then
      echo "✅ Relevant file changed: $changed" >&2
      matched=true
      break
    fi

    # 2) 새로운 구조 파일 추가 (package.json, pyproject.toml 등)
    local basename_changed
    basename_changed=$(basename "$changed")
    case "$basename_changed" in
      package.json|pyproject.toml|requirements*.txt|Dockerfile*|docker-compose*|compose.*|Makefile|Taskfile*|Procfile|*.toml|go.mod|Cargo.toml)
        echo "✅ New structure file detected: $changed" >&2
        matched=true
        break
        ;;
    esac
  done <<< "$changed_files"

  if $matched; then
    echo "🔄 Pipeline execution needed" >&2
    exit 0  # 실행 필요
  else
    echo "⏭️  No relevant changes — skipping pipeline" >&2
    exit 1  # 스킵
  fi
}

# =============================================================================
# main
# =============================================================================
case "$ACTION" in
  generate)
    generate_manifest "$@"
    ;;
  check)
    check_changes "$@"
    ;;
  *)
    echo "Usage: manifest.sh {generate|check} [args]" >&2
    echo "  generate <scan-result.json>  — Create manifest from scan results" >&2
    echo "  check [base_ref]             — Check if relevant files changed" >&2
    exit 1
    ;;
esac
