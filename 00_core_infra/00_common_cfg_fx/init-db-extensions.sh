#!/bin/bash
set -e

# 현재 연결된 데이터베이스에서 확장을 활성화합니다.
# 이 스크립트는 docker-entrypoint.sh 에 의해 psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" 형태로 실행됩니다.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
    CREATE EXTENSION IF NOT EXISTS "vector";
EOSQL

echo "✅ uuid-ossp and vector extensions created for $POSTGRES_DB"