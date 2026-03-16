# repo-autopilot generated justfile
# Ports: main_db=5432(host:7654), data_db=5432(host:7655), redis=6379(host:6380), web_service=8000(host:9000)

set dotenv-load

backend_dir := "01_Web"
main_db_port := "7654"
data_db_port := "7655"
redis_port := "6380"
web_service_port := "9000"

# 도움말 출력
default:
    @just --list

# --- Development ---

# 전체 개발 서버 실행 (Docker 기반)
dev: docker-up

# 백엔드 개발 서버 (로컬 실행, port: 8000)
dev-backend:
    cd {{backend_dir}} && uvicorn app.main:app --reload --port 8000

# --- Build ---

build:
    cd {{backend_dir}} && poetry build

# --- Test ---

test:
    cd {{backend_dir}} && pytest

# --- Database ---

# DB 마이그레이션 (사용 중인 도구가 없으므로 stub)
db-migrate *ARGS:
    @echo "⚠️  DB migration tool not detected. Please configure manually."

# --- Docker ---

docker-up:
    docker compose up -d
docker-down:
    docker compose down
docker-build:
    docker compose build
docker-logs *ARGS:
    docker compose logs -f {{ARGS}}

# --- Utility ---

check-env:
    @test -n "$MAIN_DB_URL" || (echo "❌ MAIN_DB_URL not set" && exit 1)
    @test -n "$DATA_DB_URL" || (echo "❌ DATA_DB_URL not set" && exit 1)
    @test -n "$REDIS_URL" || (echo "❌ REDIS_URL not set" && exit 1)
    @echo "✅ All env vars OK"

clean:
    find . -type d -name __pycache__ -exec rm -rf {} +
    rm -rf {{backend_dir}}/.pytest_cache {{backend_dir}}/.mypy_cache

# --- Deploy ---

deploy:
    @echo "⚠️  Deploy not configured. Edit this recipe for your deployment target."
