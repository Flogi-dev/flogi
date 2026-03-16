#!/usr/bin/env bash
# =============================================================================
# scanner.sh — repo-autopilot Step 1: Repository Scanner (v2.1)
#
# grep 기반으로 레포에서 서버/포트/실행 관련 정보를 수집하여
# scan-result.json 형식으로 stdout에 출력한다.
#
# v2.1 변경사항:
#   - raw_matches → context_blocks (파편화된 grep 결과를 유기적으로 연결)
#   - 포트 감지 노이즈 필터링 강화 (연도, 무관한 숫자 제외)
#   - Dockerfile 멀티스테이지 그룹핑 (dev/prod 구분)
#   - docker-compose build target/profile 추출
#   - grep 키워드 확장 + 필터링 기준 추가
#
# Usage: bash .autopilot/scanner.sh [TARGET_DIR]
#        TARGET_DIR 미지정 시 현재 디렉터리 스캔
# =============================================================================
set -uo pipefail

# --- 설정 ---
TARGET_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# 제외 디렉터리
DEFAULT_EXCLUDES="node_modules .git __pycache__ .next venv .venv dist build .cache .autopilot .claude .idea .vscode coverage .nyc_output .turbo .parcel-cache sample docs test tests e2e cypress .obsidian vendor bower_components"

# grep 호환성: GNU grep 사용 (macOS에서는 ggrep 필요할 수 있음)
GREP_CMD="grep"
if command -v ggrep &>/dev/null; then
  GREP_CMD="ggrep"
fi

# Context merge 설정: 같은 파일에서 N줄 이내 grep 히트는 하나의 블록으로 병합
CONTEXT_MERGE_GAP=3

# --- 유틸 함수 ---
build_exclude_opts() {
  local opts=""
  for dir in $DEFAULT_EXCLUDES; do
    opts="$opts --exclude-dir=$dir"
  done
  echo "$opts"
}

EXCLUDE_OPTS=$(build_exclude_opts)

# 안전한 grep: 매칭 없어도 에러 안 남
safe_grep() {
  $GREP_CMD $EXCLUDE_OPTS "$@" 2>/dev/null || true
}

# 결과를 JSON 배열 문자열로 변환 (중복 제거, jq로 안전한 이스케이프)
lines_to_json_array() {
  sort -u | jq -R '.' | jq -s '.'
}

# 절대경로 → 상대경로 변환
to_relpath() {
  sed "s|^${TARGET_DIR}/||;s|^\./||"
}

# =============================================================================
# Context Blocks 시스템 — 파편화된 grep 결과를 유기적으로 연결
# =============================================================================
# 모든 grep 히트를 수집 → 같은 파일 내 인접 라인 병합 → 범위 전체를 읽어서 출력

# 카테고리별 grep 결과를 임시 파일에 수집
# 형식: category\trelative_path\tline_number
collect_grep_hits() {
  local category="$1"
  shift
  # safe_grep -rn 결과에서 file:line:content 파싱
  safe_grep -rn "$@" "$TARGET_DIR" | while IFS= read -r line; do
    local filepath linenum
    # grep -rn 출력: filepath:linenum:content
    filepath=$(echo "$line" | cut -d: -f1 | to_relpath)
    linenum=$(echo "$line" | cut -d: -f2)
    # linenum이 숫자인지 확인
    if [[ "$linenum" =~ ^[0-9]+$ ]]; then
      printf '%s\t%s\t%s\n' "$category" "$filepath" "$linenum"
    fi
  done
}

# 수집된 히트를 파일별로 그룹핑 → 인접 라인 병합 → context_blocks JSON 생성
merge_and_read_context_blocks() {
  local hits_file="$1"

  [[ ! -s "$hits_file" ]] && echo "[]" && return

  # 파일별로 정렬: file → line_number 순
  sort -t$'\t' -k2,2 -k3,3n "$hits_file" > "$TMP_DIR/sorted_hits.tsv"

  # 파일별 그룹핑 + 범위 병합
  local prev_file="" range_start=0 range_end=0
  local categories=""
  local blocks_json="["
  local first_block=true

  emit_block() {
    local file="$1" start="$2" end="$3" cats="$4"
    # 파일이 존재하는지 + 읽을 수 있는지
    local full_path="$TARGET_DIR/$file"
    [[ ! -f "$full_path" ]] && return

    # 라인 범위 읽기 (최대 15줄로 제한)
    local max_end=$((start + 14))
    [[ $end -gt $max_end ]] && end=$max_end

    local content
    content=$(sed -n "${start},${end}p" "$full_path" 2>/dev/null | head -15 | cut -c1-500)
    [[ -z "$content" ]] && return
    # content 최대 2KB 제한 (minified JS 등 대용량 라인 방지)
    if [[ ${#content} -gt 2048 ]]; then
      content="${content:0:2048}...(truncated)"
    fi

    local cats_json
    cats_json=$(echo "$cats" | tr ',' '\n' | sort -u | jq -R '.' | jq -s '.')

    $first_block || blocks_json+=","
    first_block=false
    blocks_json+=$(jq -n \
      --arg file "$file" \
      --arg lines "${start}-${end}" \
      --argjson categories "$cats_json" \
      --arg content "$content" \
      '{file: $file, lines: $lines, categories: $categories, content: $content}')
  }

  while IFS=$'\t' read -r cat file linenum; do
    [[ -z "$file" || -z "$linenum" ]] && continue

    if [[ "$file" != "$prev_file" ]]; then
      # 이전 파일의 마지막 블록 emit
      if [[ -n "$prev_file" ]]; then
        emit_block "$prev_file" "$range_start" "$range_end" "$categories"
      fi
      prev_file="$file"
      range_start=$linenum
      range_end=$linenum
      categories="$cat"
    elif (( linenum <= range_end + CONTEXT_MERGE_GAP )); then
      # 인접한 라인 → 기존 범위 확장
      range_end=$linenum
      # 카테고리 추가
      [[ "$categories" != *"$cat"* ]] && categories="${categories},${cat}"
    else
      # 새 범위 시작 → 이전 블록 emit
      emit_block "$prev_file" "$range_start" "$range_end" "$categories"
      range_start=$linenum
      range_end=$linenum
      categories="$cat"
    fi
  done < "$TMP_DIR/sorted_hits.tsv"

  # 마지막 블록
  if [[ -n "$prev_file" ]]; then
    emit_block "$prev_file" "$range_start" "$range_end" "$categories"
  fi

  blocks_json+="]"
  echo "$blocks_json"
}

# 모든 카테고리의 grep 실행 → context_blocks 생성
build_context_blocks() {
  local hits_file="$TMP_DIR/all_hits.tsv"
  > "$hits_file"

  local include_code='--include=*.py --include=*.ts --include=*.tsx --include=*.js --include=*.jsx'
  local include_config='--include=*.yml --include=*.yaml --include=*.toml --include=*.json --include=*.cfg --include=*.ini'
  local include_build='--include=*.sh --include=Makefile --include=Dockerfile* --include=Procfile --include=Taskfile*'
  local include_env='--include=*.env* --include=.env*'
  local include_docker='--include=docker-compose* --include=compose.*'

  # === 카테고리 1: server_commands (서버 실행/관리 명령어) ===
  collect_grep_hits "server" \
    -E '(uvicorn|gunicorn|flask[[:space:]]+run|next[[:space:]]+(dev|start|build)|npm[[:space:]]+run[[:space:]]+(dev|start|build)|yarn[[:space:]]+(dev|start|build)|pnpm[[:space:]]+(dev|start|build)|bun[[:space:]]+(run[[:space:]]+)?dev|python.*main\.py|node[[:space:]]+.*server|deno[[:space:]]+(run|task)|cargo[[:space:]]+run|go[[:space:]]+run|air([[:space:]]|$)|nodemon|tsx[[:space:]]+watch|ts-node|pm2[[:space:]]+start|supervisord|celery[[:space:]]+worker|dramatiq|rq[[:space:]]+worker|huey|hypercorn|granian|litestar)' \
    --include="*.py" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    --include="*.sh" --include="Makefile" --include="Dockerfile*" --include="*.yml" --include="*.yaml" \
    --include="*.toml" --include="*.json" --include="Procfile" --include="Taskfile*" \
    >> "$hits_file"

  # === 카테고리 2: port_references (포트 번호 참조) ===
  # 필터: .env*, docker-compose*, Dockerfile*, config 파일에서만 포트 컨텍스트 검색
  collect_grep_hits "port" \
    -E '(PORT[[:space:]]*[=:][[:space:]]*[0-9]+|port[[:space:]]*[=:][[:space:]]*[0-9]+|--port[[:space:]]+[0-9]+|-p[[:space:]]+[0-9]+:[0-9]+|expose:[[:space:]]*$|EXPOSE[[:space:]]+[0-9]+|ports:[[:space:]]*$|"[0-9]+:[0-9]+")' \
    --include="*.env*" --include=".env*" --include="docker-compose*" --include="compose.*" \
    --include="Dockerfile*" --include="*.yml" --include="*.yaml" --include="*.toml" \
    --include="*.py" --include="*.ts" --include="*.js" \
    >> "$hits_file"

  # === 카테고리 3: docker (Docker 관련) ===
  # Docker/Compose 파일에서만 검색 (일반 YAML의 target:/build: 오탐 방지)
  collect_grep_hits "docker" \
    -E '(docker[[:space:]]+compose|docker-compose|docker[[:space:]]+run|docker[[:space:]]+build|FROM[[:space:]]+[^[:space:]]+|EXPOSE[[:space:]]+[0-9]+|target:[[:space:]]|profiles:[[:space:]]*$|depends_on:[[:space:]]*$|healthcheck:|restart:[[:space:]])' \
    --include="Dockerfile*" --include="docker-compose*" --include="compose.*" \
    >> "$hits_file"
  # Makefile/sh에서는 docker 명령어만 검색
  collect_grep_hits "docker" \
    -E '(docker[[:space:]]+compose|docker-compose|docker[[:space:]]+run|docker[[:space:]]+build|docker[[:space:]]+push)' \
    --include="*.sh" --include="Makefile" \
    >> "$hits_file"

  # === 카테고리 4: database (데이터베이스 관련) ===
  # 설정/연결 파일에서만 (API 핸들러 등 제외)
  collect_grep_hits "database" \
    -E '(DATABASE_URL|REDIS_URL|MONGO_URL|alembic[[:space:]]+(upgrade|downgrade|revision|init)|prisma[[:space:]]+(migrate|generate|push)|create_async_engine|create_engine|db[[:space:]]+push|db[[:space:]]+seed)' \
    --include="*.env*" --include=".env*" --include="*.toml" --include="*.yml" --include="*.yaml" \
    --include="*.ini" --include="*.cfg" --include="*.sh" --include="Makefile" \
    | $GREP_CMD -v 'alembic/versions/' 2>/dev/null \
    >> "$hits_file"
  # Python/JS에서는 DB 설정 파일만 (config, database, db 파일명)
  collect_grep_hits "database" \
    -E '(DATABASE_URL|REDIS_URL|create_async_engine|create_engine|SQLALCHEMY_DATABASE)' \
    --include="*config*.py" --include="*database*.py" --include="*db*.py" \
    --include="*config*.ts" --include="*database*.ts" --include="*db*.ts" \
    | $GREP_CMD -v 'alembic/versions/' 2>/dev/null \
    >> "$hits_file"

  # === 카테고리 5: deploy (배포 관련) ===
  collect_grep_hits "deploy" \
    -E '(fly[[:space:]]+deploy|vercel[[:space:]]+(--prod|deploy)|netlify[[:space:]]+deploy|railway[[:space:]]+up|render\.com|heroku|aws[[:space:]]+(s3|ecs|ecr|lambda)|gcloud[[:space:]]+run|kubectl[[:space:]]+apply|helm[[:space:]]+install|docker[[:space:]]+push|ghcr\.io|ecr\.[^[:space:]]+\.amazonaws)' \
    --include="*.sh" --include="Makefile" --include="*.yml" --include="*.yaml" \
    --include="*.toml" --include="Procfile" --include="Taskfile*" \
    >> "$hits_file"

  # === 카테고리 6: env_config (환경설정/시크릿 관리) ===
  collect_grep_hits "env_config" \
    -E '(dotenv|load_dotenv|from_env|env_file|secret|vault|ssm|parameter.store|\.env\.(local|production|development|staging|test))' \
    --include="*.py" --include="*.ts" --include="*.js" --include="*.yml" --include="*.yaml" \
    --include="*.toml" --include="docker-compose*" --include="compose.*" \
    >> "$hits_file"

  # === 카테고리 7: ci_cd (CI/CD 파이프라인) ===
  # BSD grep은 --include에 경로 패턴 미지원 → *.yml로 넓히고 경로 필터 후처리
  collect_grep_hits "ci_cd" \
    -E '(github.com/actions|uses:[[:space:]]+actions/|runs-on:|jobs:|pipeline:|on:[[:space:]]*$|workflow_dispatch)' \
    --include="*.yml" --include="*.yaml" --include="Jenkinsfile" \
    | $GREP_CMD -E '(\.github/workflows/|\.gitlab-ci\.|\.circleci/|Jenkinsfile)' 2>/dev/null \
    >> "$hits_file"

  # 히트 수 제한: 카테고리별 균등 할당 (카테고리당 max 30, 파일당 max 5)
  # 특정 카테고리(server/port)가 전체를 독점하는 문제 방지
  awk -F'\t' '{
    file_count[$2]++
    cat_count[$1]++
    if (file_count[$2] <= 5 && cat_count[$1] <= 30) print
  }' "$hits_file" > "$TMP_DIR/limited_hits.tsv"
  head -210 "$TMP_DIR/limited_hits.tsv" > "$TMP_DIR/final_hits.tsv"

  merge_and_read_context_blocks "$TMP_DIR/final_hits.tsv"
}

# --- Step 1: 프로젝트 이름 ---
PROJECT_NAME=$(basename "$(cd "$TARGET_DIR" && pwd)")

# --- Step 2: 서버 실행 명령어 감지 (구조화된 결과용) ---
detect_server_commands() {
  safe_grep -rn \
    -E '(uvicorn|gunicorn|flask[[:space:]]+run|next[[:space:]]+(dev|start)|npm[[:space:]]+run[[:space:]]+(dev|start)|yarn[[:space:]]+(dev|start)|pnpm[[:space:]]+(dev|start)|bun[[:space:]]+(run[[:space:]]+)?dev|python.*main\.py|node[[:space:]]+.*server|deno[[:space:]]+(run|task)|cargo[[:space:]]+run|go[[:space:]]+run|air([[:space:]]|$)|nodemon|tsx[[:space:]]+watch|ts-node|pm2[[:space:]]+start|supervisord|celery[[:space:]]+worker|dramatiq|rq[[:space:]]+worker|huey|hypercorn|granian|litestar)' \
    --include="*.py" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    --include="*.sh" --include="Makefile" --include="Dockerfile*" --include="*.yml" --include="*.yaml" \
    --include="*.toml" --include="*.json" --include="Procfile" --include="Taskfile*" \
    "$TARGET_DIR" | head -50
}

# --- Step 3: 포트 번호 감지 (노이즈 필터링 강화) ---
detect_ports() {
  safe_grep -rn \
    -E '(PORT[[:space:]]*[=:][[:space:]]*[0-9]+|port[[:space:]]*[=:][[:space:]]*[0-9]+|--port[[:space:]]+[0-9]+|-p[[:space:]]+[0-9]+:[0-9]+|EXPOSE[[:space:]]+[0-9]+|"[0-9]+:[0-9]+")' \
    --include="*.py" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    --include="*.sh" --include="*.yml" --include="*.yaml" --include="*.toml" \
    --include="*.env*" --include="Dockerfile*" --include="docker-compose*" --include="compose.*" --include="*.json" \
    "$TARGET_DIR" | head -50
}

# 포트 번호 추출 — 노이즈 필터링 강화
# 제외: 연도(2020-2030), alembic revision ID, 일반 숫자 패턴
extract_port_numbers() {
  detect_ports | \
    # 알려진 노이즈 라인 제외: alembic revision, migration, version, date/year 패턴
    $GREP_CMD -v -iE '(alembic|revision|migration|version[[:space:]]*=|date|year|created|updated|timestamp|Copyright|[0-9]{4}-[0-9]{2}|[0-9]{2}/[0-9]{2}/[0-9]{4})' 2>/dev/null | \
    # 포트 컨텍스트에서만 숫자 추출
    $GREP_CMD -oE '(PORT[[:space:]]*[=:][[:space:]]*[0-9]+|port[[:space:]]*[=:][[:space:]]*[0-9]+|--port[[:space:]]+[0-9]+|EXPOSE[[:space:]]+[0-9]+|-p[[:space:]]+[0-9]+:[0-9]+|"[0-9]+:[0-9]+")' 2>/dev/null | \
    $GREP_CMD -oE '[0-9]{2,5}' 2>/dev/null | \
    # 유효 포트 범위: 80-65535 (well-known 포트도 허용)
    awk '$1 >= 80 && $1 <= 65535' | \
    # 연도 패턴 제외 (2000-2099)
    $GREP_CMD -vE '^20[0-9]{2}$' 2>/dev/null | \
    sort -un || true
}

# --- Step 4: Docker 관련 감지 ---
detect_docker() {
  safe_grep -rn \
    -E '(docker[[:space:]]+compose|docker-compose|docker[[:space:]]+run|docker[[:space:]]+build|FROM[[:space:]]+[^[:space:]]+|EXPOSE[[:space:]]+[0-9]+)' \
    --include="Dockerfile*" --include="docker-compose*" --include="compose.*" --include="*.yml" --include="*.yaml" \
    --include="*.sh" --include="Makefile" \
    "$TARGET_DIR" | head -30
}

# --- Step 5: 프레임워크 감지 ---
detect_frontend() {
  local framework="" pkg_manager="" directory="" dev_cmd="" build_cmd="" port=""

  local pkg_file
  pkg_file=$(safe_grep -rl '"next"' --include="package.json" "$TARGET_DIR" | head -1)
  if [[ -n "$pkg_file" ]]; then
    framework="next.js"
    directory=$(dirname "$pkg_file" | to_relpath)
    [[ "$directory" == "" || "$directory" == "." ]] && directory="."
  else
    pkg_file=$(safe_grep -rl '"react-scripts"\|"@vitejs/plugin-react"' --include="package.json" "$TARGET_DIR" | head -1)
    if [[ -n "$pkg_file" ]]; then
      framework="react"
      directory=$(dirname "$pkg_file" | to_relpath)
      [[ "$directory" == "" || "$directory" == "." ]] && directory="."
    fi
  fi

  if [[ -n "$directory" ]]; then
    local base="$TARGET_DIR/$directory"
    [[ "$directory" == "." ]] && base="$TARGET_DIR"

    if [[ -f "$base/pnpm-lock.yaml" ]]; then pkg_manager="pnpm"
    elif [[ -f "$base/yarn.lock" ]]; then pkg_manager="yarn"
    elif [[ -f "$base/bun.lockb" ]]; then pkg_manager="bun"
    else pkg_manager="npm"
    fi

    dev_cmd="${pkg_manager} run dev"
    build_cmd="${pkg_manager} run build"
    port="3000"
  fi

  if [[ -n "$framework" ]]; then
    cat <<EOF
{
  "framework": "$framework",
  "package_manager": "$pkg_manager",
  "directory": "$directory",
  "dev_command": "$dev_cmd",
  "build_command": "$build_cmd",
  "port": $port
}
EOF
  else
    echo "null"
  fi
}

detect_backend() {
  local framework="" pkg_manager="" directory="" dev_cmd="" port=""

  local match_file
  match_file=$(safe_grep -rl 'fastapi\|FastAPI\|uvicorn' --include="*.py" --include="requirements*.txt" --include="pyproject.toml" "$TARGET_DIR" | head -1)
  if [[ -n "$match_file" ]]; then
    framework="fastapi"
    pkg_manager="pip"
    # 프로젝트 설정 파일(pyproject.toml, requirements.txt) 위치 우선
    local config_match
    config_match=$(safe_grep -rl 'fastapi\|FastAPI\|uvicorn' --include="pyproject.toml" --include="requirements*.txt" "$TARGET_DIR" | head -1)
    if [[ -n "$config_match" ]]; then
      directory=$(dirname "$config_match" | to_relpath)
    else
      directory=$(dirname "$match_file" | to_relpath)
    fi
    [[ "$directory" == "" || "$directory" == "." ]] && directory="."

    local app_module
    app_module=$(safe_grep -rE 'uvicorn[[:space:]]+[^[:space:]]+' --include="*.sh" --include="*.py" --include="Makefile" --include="Dockerfile*" --include="*.toml" "$TARGET_DIR" | \
      ($GREP_CMD -oE 'uvicorn[[:space:]]+[a-zA-Z0-9_.]+:[a-zA-Z0-9_]+' || true) | head -1 | sed 's/uvicorn[[:space:]]*//')

    if [[ -n "$app_module" ]]; then
      dev_cmd="uvicorn ${app_module} --reload --port 8000"
    else
      dev_cmd="uvicorn app.main:app --reload --port 8000"
    fi
    port="8000"
  else
    match_file=$(safe_grep -rl 'flask\|Flask' --include="*.py" --include="requirements*.txt" --include="pyproject.toml" "$TARGET_DIR" | head -1)
    if [[ -n "$match_file" ]]; then
      framework="flask"
      pkg_manager="pip"
      config_match=$(safe_grep -rl 'flask\|Flask' --include="pyproject.toml" --include="requirements*.txt" "$TARGET_DIR" | head -1)
      if [[ -n "$config_match" ]]; then
        directory=$(dirname "$config_match" | to_relpath)
      else
        directory=$(dirname "$match_file" | to_relpath)
      fi
      [[ "$directory" == "" || "$directory" == "." ]] && directory="."
      dev_cmd="flask run --port 5000 --reload"
      port="5000"
    else
      match_file=$(safe_grep -rl 'django\|Django\|DJANGO' --include="*.py" --include="requirements*.txt" --include="pyproject.toml" "$TARGET_DIR" | head -1)
      if [[ -n "$match_file" ]]; then
        framework="django"
        pkg_manager="pip"
        config_match=$(safe_grep -rl 'django\|Django\|DJANGO' --include="pyproject.toml" --include="requirements*.txt" "$TARGET_DIR" | head -1)
        if [[ -n "$config_match" ]]; then
          directory=$(dirname "$config_match" | to_relpath)
        else
          directory=$(dirname "$match_file" | to_relpath)
        fi
        [[ "$directory" == "" || "$directory" == "." ]] && directory="."
        dev_cmd="python manage.py runserver 8000"
        port="8000"
      else
        match_file=$(safe_grep -rl '"express"' --include="package.json" "$TARGET_DIR" | head -1)
        if [[ -n "$match_file" ]]; then
          framework="express"
          pkg_manager="npm"
          directory=$(dirname "$match_file" | to_relpath)
          [[ "$directory" == "" || "$directory" == "." ]] && directory="."
          dev_cmd="npm run dev"
          port="3001"
        fi
      fi
    fi
  fi

  # pip → uv/poetry 판별
  if [[ "$pkg_manager" == "pip" ]]; then
    if [[ -f "$TARGET_DIR/uv.lock" ]] || $GREP_CMD -q '\[tool\.uv\]' "$TARGET_DIR/pyproject.toml" 2>/dev/null; then
      pkg_manager="uv"
    elif $GREP_CMD -q '\[tool\.poetry\]' "$TARGET_DIR/pyproject.toml" 2>/dev/null; then
      pkg_manager="poetry"
    fi
  fi

  if [[ -n "$framework" ]]; then
    cat <<EOF
{
  "framework": "$framework",
  "package_manager": "$pkg_manager",
  "directory": "$directory",
  "dev_command": "$dev_cmd",
  "port": $port
}
EOF
  else
    echo "null"
  fi
}

detect_database() {
  local db_type="" db_port="" migration_tool=""

  if [[ -n "$(safe_grep -rl 'postgresql\|postgres\|psycopg\|DATABASE_URL.*5432' \
    --include="*.py" --include="*.ts" --include="*.js" --include="*.env*" --include="*.toml" --include="*.yml" --include="*.yaml" \
    "$TARGET_DIR" | head -1)" ]]; then
    db_type="postgresql"
    db_port="5432"
  elif [[ -n "$(safe_grep -rl 'mysql\|MySQL\|MYSQL' \
    --include="*.py" --include="*.ts" --include="*.env*" --include="*.yml" \
    "$TARGET_DIR" | head -1)" ]]; then
    db_type="mysql"
    db_port="3306"
  elif [[ -n "$(safe_grep -rl 'mongodb\|MONGO' \
    --include="*.py" --include="*.ts" --include="*.js" --include="*.env*" \
    "$TARGET_DIR" | head -1)" ]]; then
    db_type="mongodb"
    db_port="27017"
  fi

  if [[ -n "$(safe_grep -rl 'alembic' --include="*.py" --include="*.ini" --include="*.cfg" --include="*.toml" "$TARGET_DIR" | head -1)" ]]; then
    migration_tool="alembic"
  elif [[ -n "$(safe_grep -rl 'prisma' --include="*.ts" --include="*.js" --include="*.json" "$TARGET_DIR" | head -1)" ]]; then
    migration_tool="prisma"
  elif [[ -n "$(safe_grep -rl 'manage\.py.*migrate\|django' --include="*.py" "$TARGET_DIR" | head -1)" ]]; then
    migration_tool="django"
  fi

  if [[ -n "$db_type" ]]; then
    local migration_json="null"
    [[ -n "$migration_tool" ]] && migration_json="\"$migration_tool\""
    cat <<EOF
{
  "type": "$db_type",
  "port": $db_port,
  "migration_tool": $migration_json
}
EOF
  else
    echo "null"
  fi
}

detect_vector_db() {
  local vdb_type="" vdb_port=""

  if [[ -n "$(safe_grep -rl 'qdrant\|QDRANT\|QdrantClient' \
    --include="*.py" --include="*.ts" --include="*.env*" --include="*.yml" --include="*.yaml" \
    "$TARGET_DIR" | head -1)" ]]; then
    vdb_type="qdrant"
    vdb_port="6333"
  elif [[ -n "$(safe_grep -rl 'pinecone\|PINECONE' \
    --include="*.py" --include="*.ts" --include="*.env*" \
    "$TARGET_DIR" | head -1)" ]]; then
    vdb_type="pinecone"
    vdb_port="null"
  elif [[ -n "$(safe_grep -rl 'chromadb\|CHROMA' \
    --include="*.py" --include="*.ts" --include="*.env*" \
    "$TARGET_DIR" | head -1)" ]]; then
    vdb_type="chromadb"
    vdb_port="8000"
  elif [[ -n "$(safe_grep -rl 'weaviate\|WEAVIATE' \
    --include="*.py" --include="*.ts" --include="*.env*" \
    "$TARGET_DIR" | head -1)" ]]; then
    vdb_type="weaviate"
    vdb_port="8080"
  fi

  if [[ -n "$vdb_type" ]]; then
    cat <<EOF
{
  "type": "$vdb_type",
  "port": $vdb_port
}
EOF
  else
    echo "null"
  fi
}

# --- Step 6: 환경변수 키 수집 (값 제외, 키만) ---
detect_env_vars() {
  safe_grep -rh '^[A-Z][A-Z0-9_]*=' \
    --include=".env*" --include="*.env*" \
    "$TARGET_DIR" | \
    sed 's/=.*//' | sort -u | lines_to_json_array
}

# --- Step 7: 테스트 명령어 감지 ---
detect_test_commands() {
  local frontend_test="" backend_test=""

  if [[ -n "$(safe_grep -rl '"vitest"\|"jest"\|"@testing-library"' --include="package.json" "$TARGET_DIR" | head -1)" ]]; then
    if [[ -n "$(safe_grep -rl '"vitest"' --include="package.json" "$TARGET_DIR" | head -1)" ]]; then
      frontend_test="npx vitest"
    else
      frontend_test="npm test"
    fi
  fi

  if [[ -n "$(safe_grep -rl 'pytest\|unittest' --include="*.py" --include="*.toml" --include="*.cfg" --include="requirements*.txt" "$TARGET_DIR" | head -1)" ]]; then
    backend_test="pytest"
  fi

  echo "{"
  [[ -n "$frontend_test" ]] && echo "  \"frontend\": \"$frontend_test\","
  [[ -n "$backend_test" ]] && echo "  \"backend\": \"$backend_test\","
  echo "  \"_\": null"
  echo "}"
}

# --- Step 7.5: package.json scripts 섹션 전체 추출 ---
detect_npm_scripts() {
  local pkg_files
  pkg_files=$(find "$TARGET_DIR" -maxdepth 3 -name "package.json" \
    -not -path "*/node_modules/*" -not -path "*/.git/*" -not -path "*/.autopilot/*" 2>/dev/null)

  local results="["
  local first=true

  while IFS= read -r pkg; do
    [[ -z "$pkg" || ! -f "$pkg" ]] && continue
    local relpath
    relpath=$(echo "$pkg" | to_relpath)
    local scripts
    scripts=$(jq -r '.scripts // empty' "$pkg" 2>/dev/null)
    if [[ -n "$scripts" && "$scripts" != "null" ]]; then
      $first || results+=","
      first=false
      results+=$(jq -n --arg path "$relpath" --argjson scripts "$scripts" '{"path": $path, "scripts": $scripts}')
    fi
  done <<< "$pkg_files"

  results+="]"
  echo "$results"
}

# --- Step 7.6: pyproject.toml scripts/엔트리포인트 추출 ---
detect_python_scripts() {
  if [[ -f "$TARGET_DIR/pyproject.toml" ]] && command -v python3 &>/dev/null; then
    python3 -c "
import tomllib, json, sys
try:
    with open('$TARGET_DIR/pyproject.toml', 'rb') as f:
        data = tomllib.load(f)
    scripts = data.get('project', {}).get('scripts', {})
    if not scripts:
        scripts = data.get('tool', {}).get('poetry', {}).get('scripts', {})
    print(json.dumps(scripts if scripts else {}))
except Exception:
    print('{}')
" 2>/dev/null || echo "{}"
  else
    echo "{}"
  fi
}

# --- Step 7.7: Makefile 타겟 추출 ---
detect_makefile_targets() {
  local makefiles
  makefiles=$(find "$TARGET_DIR" -maxdepth 2 -name "Makefile" \
    -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/.autopilot/*" 2>/dev/null)

  local targets="["
  local first=true

  while IFS= read -r mf; do
    [[ -z "$mf" || ! -f "$mf" ]] && continue
    local relpath
    relpath=$(echo "$mf" | to_relpath)
    local tgts
    tgts=$($GREP_CMD -E '^[a-zA-Z_][a-zA-Z0-9_-]*[[:space:]]*:' "$mf" 2>/dev/null | \
      sed 's/[[:space:]]*:.*//' | sort -u | jq -R '.' | jq -s '.')
    $first || targets+=","
    first=false
    targets+=$(jq -n --arg path "$relpath" --argjson targets "$tgts" '{"path": $path, "targets": $targets}')
  done <<< "$makefiles"

  targets+="]"
  echo "$targets"
}

# --- Step 7.8: Dockerfile 멀티스테이지 그룹핑 ---
# v2.1: FROM 스테이지별로 CMD/ENTRYPOINT/EXPOSE/WORKDIR 분리
detect_dockerfile_commands() {
  local results="["
  local first=true
  local dockerfiles
  dockerfiles=$(find "$TARGET_DIR" -maxdepth 3 -name "Dockerfile*" \
    -not -path "*/.git/*" -not -path "*/node_modules/*" -not -path "*/.autopilot/*" 2>/dev/null)

  while IFS= read -r df; do
    [[ -z "$df" || ! -f "$df" ]] && continue
    local relpath
    relpath=$(echo "$df" | to_relpath)

    # 스테이지별 파싱: FROM → CMD/ENTRYPOINT/EXPOSE/WORKDIR 그룹핑
    local stages_json
    stages_json=$(awk '
      BEGIN { stage_idx=0; cmd_idx=0; printf "[" }
      /^FROM/ {
        # 이전 stage 닫기
        if (stage_idx > 0) printf "]},"
        # FROM image AS name 에서 name 추출
        name = ""
        for (i=1; i<=NF; i++) {
          if (tolower($i) == "as" && i < NF) {
            name = $(i+1)
            break
          }
        }
        if (name == "") {
          # base image에서 의미 있는 이름 추출 (예: python:3.11 → python)
          img = $2
          sub(/:.*/, "", img)       # 태그 제거
          sub(/.*\//, "", img)      # 레지스트리/네임스페이스 제거
          if (img == "" || img == "scratch") name = img == "" ? "stage-" stage_idx : "scratch"
          else name = img
        }
        stage_idx++
        cmd_idx = 0
        printf "{\"stage\":\"%s\",\"from\":\"%s\",\"commands\":[", name, $2
      }
      /^[[:space:]]*(CMD|ENTRYPOINT|EXPOSE|WORKDIR|HEALTHCHECK)[[:space:]]/ {
        if (stage_idx > 0) {
          line = $0
          gsub(/"/,"\\\"", line)
          sub(/^[[:space:]]+/, "", line)
          if (cmd_idx > 0) printf ","
          printf "\"%s\"", line
          cmd_idx++
        }
      }
      END {
        if (stage_idx > 0) printf "]}"
        printf "]"
      }
    ' "$df" 2>/dev/null)

    # 유효한 JSON인지 확인
    if echo "$stages_json" | jq '.' &>/dev/null && [[ "$stages_json" != "[]" ]]; then
      $first || results+=","
      first=false
      results+=$(jq -n --arg path "$relpath" --argjson stages "$stages_json" '{"path": $path, "stages": $stages}')
    fi
  done <<< "$dockerfiles"

  results+="]"
  echo "$results"
}

# --- Step 7.9: 배포 설정 감지 ---
detect_deploy_config() {
  local results="{"
  local first=true

  if [[ -f "$TARGET_DIR/Procfile" ]]; then
    $first || results+=","
    first=false
    local procfile_content
    procfile_content=$(cat "$TARGET_DIR/Procfile" | jq -R '.' | jq -s '.')
    results+="\"procfile\": $procfile_content"
  fi

  for cfg_file in fly.toml render.yaml railway.json vercel.json netlify.toml; do
    if [[ -f "$TARGET_DIR/$cfg_file" ]]; then
      $first || results+=","
      first=false
      local key
      key=$(echo "$cfg_file" | sed 's/[.-]/_/g')
      results+="\"$key\": true"
    fi
  done

  results+="}"
  echo "$results"
}

# --- Step 7.10: 모노레포 도구 감지 ---
detect_monorepo_config() {
  local results="{"
  local first=true

  if [[ -f "$TARGET_DIR/turbo.json" ]]; then
    $first || results+=","
    first=false
    local pipelines
    pipelines=$(jq -r '.pipeline // .tasks // {} | keys[]' "$TARGET_DIR/turbo.json" 2>/dev/null | jq -R '.' | jq -s '.')
    results+="\"turborepo\": $pipelines"
  fi

  if [[ -f "$TARGET_DIR/nx.json" ]]; then
    $first || results+=","
    first=false
    results+="\"nx\": true"
  fi

  if [[ -f "$TARGET_DIR/pnpm-workspace.yaml" ]]; then
    $first || results+=","
    first=false
    local packages
    packages=$(safe_grep -E '^[[:space:]]*-[[:space:]]' "$TARGET_DIR/pnpm-workspace.yaml" | sed 's/^[[:space:]]*-[[:space:]]*//' | jq -R '.' | jq -s '.')
    results+="\"pnpm_workspaces\": $packages"
  fi

  if [[ -f "$TARGET_DIR/lerna.json" ]]; then
    $first || results+=","
    first=false
    results+="\"lerna\": true"
  fi

  if [[ -f "$TARGET_DIR/package.json" ]]; then
    local workspaces
    workspaces=$(jq -r '.workspaces // empty' "$TARGET_DIR/package.json" 2>/dev/null)
    if [[ -n "$workspaces" && "$workspaces" != "null" ]]; then
      $first || results+=","
      first=false
      results+="\"npm_workspaces\": $workspaces"
    fi
  fi

  results+="}"
  echo "$results"
}

# --- Step 8: Docker Compose 상세 정보 (v2.1: build target/profile 추가) ---
detect_docker_info() {
  local compose_file=""
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$TARGET_DIR/$f" ]]; then
      compose_file="$f"
      break
    fi
  done

  if [[ -n "$compose_file" ]]; then
    local full_path="$TARGET_DIR/$compose_file"

    # 서비스 목록 + 상세 정보를 Python YAML 파서로 통합 추출
    local python_result
    python_result=$(python3 -c "
import sys, json
try:
    import yaml
except ImportError:
    # yaml 없으면 grep 폴백 (services만)
    print(json.dumps({'services': [], 'service_details': {}}))
    sys.exit(0)
try:
    with open('$full_path', 'r') as f:
        data = yaml.safe_load(f)
    svcs = data.get('services', {})
    service_names = sorted(svcs.keys()) if svcs else []
    result = {}
    for name, svc in svcs.items():
        info = {}
        # build target
        build = svc.get('build', {})
        if isinstance(build, dict):
            if 'target' in build:
                info['build_target'] = build['target']
            if 'dockerfile' in build:
                info['dockerfile'] = build['dockerfile']
        # profiles
        if 'profiles' in svc:
            info['profiles'] = svc['profiles']
        # ports
        if 'ports' in svc:
            info['ports'] = [str(p) for p in svc['ports']]
        # depends_on
        deps = svc.get('depends_on', {})
        if isinstance(deps, list):
            info['depends_on'] = deps
        elif isinstance(deps, dict):
            info['depends_on'] = list(deps.keys())
        # environment (키만)
        env = svc.get('environment', {})
        if isinstance(env, dict):
            info['env_keys'] = list(env.keys())[:10]
        elif isinstance(env, list):
            info['env_keys'] = [e.split('=')[0] for e in env][:10]
        # volumes (마운트 경로만)
        vols = svc.get('volumes', [])
        if vols:
            info['volumes'] = [str(v).split(':')[0] if ':' in str(v) else str(v) for v in vols][:5]
        if info:
            result[name] = info
    print(json.dumps({'services': service_names, 'service_details': result}))
except Exception as e:
    print(json.dumps({'services': [], 'service_details': {}}))
" 2>/dev/null || echo '{"services":[],"service_details":{}}')

    local services service_details
    services=$(echo "$python_result" | jq '.services')
    service_details=$(echo "$python_result" | jq '.service_details')

    # Python yaml이 없는 환경 폴백: grep으로 서비스 추출
    if [[ "$services" == "[]" ]]; then
      services=$(safe_grep -E '^[[:space:]]{2}[a-zA-Z][a-zA-Z0-9_-]*[[:space:]]*:' "$full_path" | \
        sed 's/^[[:space:]]*//' | sed 's/:.*//' | sort -u | \
        $GREP_CMD -vE '^(volumes|networks|configs|secrets|x-)$' | lines_to_json_array)
      service_details="{}"
    fi

    jq -n \
      --arg compose_file "$compose_file" \
      --argjson services "$services" \
      --argjson service_details "$service_details" \
      '{
        compose_file: $compose_file,
        services: $services,
        service_details: $service_details
      }'
  else
    echo "null"
  fi
}

# --- 메인: jq로 안전한 JSON 조립 ---
main() {
  local frontend_json backend_json db_json vdb_json docker_json
  local env_vars test_cmds ports_json
  local npm_scripts python_scripts makefile_targets dockerfile_cmds
  local deploy_config monorepo_config
  local context_blocks

  # 기존 감지
  frontend_json=$(detect_frontend)
  backend_json=$(detect_backend)
  db_json=$(detect_database)
  vdb_json=$(detect_vector_db)
  docker_json=$(detect_docker_info)
  env_vars=$(detect_env_vars)
  test_cmds=$(detect_test_commands)
  ports_json=$(extract_port_numbers | lines_to_json_array)

  # 확장 컨텍스트
  npm_scripts=$(detect_npm_scripts)
  python_scripts=$(detect_python_scripts)
  makefile_targets=$(detect_makefile_targets)
  dockerfile_cmds=$(detect_dockerfile_commands)
  deploy_config=$(detect_deploy_config)
  monorepo_config=$(detect_monorepo_config)

  # Context Blocks — 파편화된 grep 결과를 유기적으로 연결
  context_blocks=$(build_context_blocks)

  jq -n \
    --arg project_name "$PROJECT_NAME" \
    --argjson frontend "$frontend_json" \
    --argjson backend "$backend_json" \
    --argjson database "$db_json" \
    --argjson vector_db "$vdb_json" \
    --argjson docker "$docker_json" \
    --argjson ports "$ports_json" \
    --argjson env_vars "$env_vars" \
    --argjson test_cmds "$test_cmds" \
    --argjson npm_scripts "$npm_scripts" \
    --argjson python_scripts "$python_scripts" \
    --argjson makefile_targets "$makefile_targets" \
    --argjson dockerfile_cmds "$dockerfile_cmds" \
    --argjson deploy_config "$deploy_config" \
    --argjson monorepo_config "$monorepo_config" \
    --argjson context_blocks "$context_blocks" \
    '{
      project_name: $project_name,
      detected_stack: {
        frontend: $frontend,
        backend: $backend,
        database: $database,
        vector_db: $vector_db,
        docker: $docker
      },
      ports_in_use: $ports,
      env_vars: $env_vars,
      test_commands: $test_cmds,
      extended_context: {
        npm_scripts: $npm_scripts,
        python_scripts: $python_scripts,
        makefile_targets: $makefile_targets,
        dockerfile_commands: $dockerfile_cmds,
        deploy_config: $deploy_config,
        monorepo: $monorepo_config
      },
      context_blocks: $context_blocks
    }'
}

main
