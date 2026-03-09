#!/usr/bin/env bash
# =============================================================================
# scanner.sh — repo-autopilot Step 1: Repository Scanner
#
# grep 기반으로 레포에서 서버/포트/실행 관련 정보를 수집하여
# scan-result.json 형식으로 stdout에 출력한다.
#
# Usage: bash .autopilot/scanner.sh [TARGET_DIR]
#        TARGET_DIR 미지정 시 현재 디렉터리 스캔
# =============================================================================
set -uo pipefail

# --- 설정 ---
TARGET_DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 제외 디렉터리
DEFAULT_EXCLUDES="node_modules .git __pycache__ .next venv .venv dist build .cache .autopilot .claude .idea .vscode"

# grep 호환성: GNU grep 사용 (macOS에서는 ggrep 필요할 수 있음)
GREP_CMD="grep"
if command -v ggrep &>/dev/null; then
  GREP_CMD="ggrep"
fi

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

# --- Step 1: 프로젝트 이름 ---
PROJECT_NAME=$(basename "$(cd "$TARGET_DIR" && pwd)")

# --- Step 2: 서버 실행 명령어 감지 ---
detect_server_commands() {
  safe_grep -rn \
    -E '(uvicorn|gunicorn|flask run|next dev|next start|npm run dev|npm start|yarn dev|pnpm dev|python.*main\.py|node.*server|deno run|cargo run|go run)' \
    --include="*.py" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    --include="*.sh" --include="Makefile" --include="Dockerfile*" --include="*.yml" --include="*.yaml" \
    --include="*.toml" --include="*.json" \
    "$TARGET_DIR" | head -50
}

# --- Step 3: 포트 번호 감지 ---
detect_ports() {
  safe_grep -rn \
    -E '(port\s*[=:]\s*[0-9]+|PORT\s*[=:]\s*[0-9]+|:\s*[0-9]{4,5}[^0-9/]|--port\s+[0-9]+|-p\s+[0-9]+:[0-9]+|expose:\s*[0-9]+|ports:)' \
    --include="*.py" --include="*.ts" --include="*.tsx" --include="*.js" --include="*.jsx" \
    --include="*.sh" --include="*.yml" --include="*.yaml" --include="*.toml" \
    --include="*.env*" --include="Dockerfile*" --include="docker-compose*" --include="*.json" \
    "$TARGET_DIR" | head -50
}

extract_port_numbers() {
  detect_ports | \
    ($GREP_CMD -oE '[0-9]{4,5}' || true) | \
    awk '$1 >= 1024 && $1 <= 65535' | \
    sort -un
}

# --- Step 4: Docker 관련 감지 ---
detect_docker() {
  safe_grep -rn \
    -E '(docker compose|docker-compose|docker run|docker build|FROM\s+\S+|EXPOSE\s+[0-9]+)' \
    --include="Dockerfile*" --include="docker-compose*" --include="*.yml" --include="*.yaml" \
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
    directory=$(dirname "$pkg_file" | sed "s|^$TARGET_DIR/||;s|^$TARGET_DIR||")
    [[ "$directory" == "" || "$directory" == "." ]] && directory="."
  else
    pkg_file=$(safe_grep -rl '"react-scripts"\|"@vitejs/plugin-react"' --include="package.json" "$TARGET_DIR" | head -1)
    if [[ -n "$pkg_file" ]]; then
      framework="react"
      directory=$(dirname "$pkg_file" | sed "s|^$TARGET_DIR/||;s|^$TARGET_DIR||")
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
    directory=$(dirname "$match_file" | sed "s|^$TARGET_DIR/||;s|^$TARGET_DIR||")
    [[ "$directory" == "" || "$directory" == "." ]] && directory="."

    local app_module
    app_module=$(safe_grep -rE 'uvicorn\s+\S+' --include="*.sh" --include="*.py" --include="Makefile" --include="Dockerfile*" --include="*.toml" "$TARGET_DIR" | \
      ($GREP_CMD -oE 'uvicorn\s+[a-zA-Z0-9_.]+:[a-zA-Z0-9_]+' || true) | head -1 | sed 's/uvicorn\s*//')

    if [[ -n "$app_module" ]]; then
      dev_cmd="uvicorn ${app_module} --reload --port 8000"
    else
      dev_cmd="uvicorn app.main:app --reload --port 8000"
    fi
    port="8000"
  else
    match_file=$(safe_grep -rl 'flask\|Flask' --include="*.py" --include="requirements*.txt" "$TARGET_DIR" | head -1)
    if [[ -n "$match_file" ]]; then
      framework="flask"
      pkg_manager="pip"
      directory=$(dirname "$match_file" | sed "s|^$TARGET_DIR/||;s|^$TARGET_DIR||")
      [[ "$directory" == "" || "$directory" == "." ]] && directory="."
      dev_cmd="flask run --port 5000 --reload"
      port="5000"
    else
      match_file=$(safe_grep -rl 'django\|Django\|DJANGO' --include="*.py" --include="requirements*.txt" "$TARGET_DIR" | head -1)
      if [[ -n "$match_file" ]]; then
        framework="django"
        pkg_manager="pip"
        directory=$(dirname "$match_file" | sed "s|^$TARGET_DIR/||;s|^$TARGET_DIR||")
        [[ "$directory" == "" || "$directory" == "." ]] && directory="."
        dev_cmd="python manage.py runserver 8000"
        port="8000"
      else
        match_file=$(safe_grep -rl '"express"' --include="package.json" "$TARGET_DIR" | head -1)
        if [[ -n "$match_file" ]]; then
          framework="express"
          pkg_manager="npm"
          directory=$(dirname "$match_file" | sed "s|^$TARGET_DIR/||;s|^$TARGET_DIR||")
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

# --- Step 8: Docker 정보 구조화 ---
detect_docker_info() {
  local compose_file=""
  for f in docker-compose.yml docker-compose.yaml compose.yml compose.yaml; do
    if [[ -f "$TARGET_DIR/$f" ]]; then
      compose_file="$f"
      break
    fi
  done

  if [[ -n "$compose_file" ]]; then
    local services
    services=$(safe_grep -E '^\s{2}[a-zA-Z][a-zA-Z0-9_-]*\s*:' "$TARGET_DIR/$compose_file" | \
      sed 's/^\s*//' | sed 's/:.*//' | sort -u | lines_to_json_array)

    cat <<EOF
{
  "compose_file": "$compose_file",
  "services": $services
}
EOF
  else
    echo "null"
  fi
}

# --- 메인: jq로 안전한 JSON 조립 ---
main() {
  local frontend_json backend_json db_json vdb_json docker_json
  local env_vars test_cmds ports_json
  local raw_servers raw_ports raw_docker

  frontend_json=$(detect_frontend)
  backend_json=$(detect_backend)
  db_json=$(detect_database)
  vdb_json=$(detect_vector_db)
  docker_json=$(detect_docker_info)
  env_vars=$(detect_env_vars)
  test_cmds=$(detect_test_commands)
  ports_json=$(extract_port_numbers | lines_to_json_array)

  raw_servers=$(detect_server_commands | head -10 | lines_to_json_array)
  raw_ports=$(detect_ports | head -10 | lines_to_json_array)
  raw_docker=$(detect_docker | head -10 | lines_to_json_array)

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
    --argjson raw_servers "$raw_servers" \
    --argjson raw_ports "$raw_ports" \
    --argjson raw_docker "$raw_docker" \
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
      raw_matches: {
        server_commands: $raw_servers,
        port_references: $raw_ports,
        docker_references: $raw_docker
      }
    }'
}

main
