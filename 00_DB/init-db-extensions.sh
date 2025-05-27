#!/bin/bash
set -e

# PGUSER, PGPASSWORD, PGDATABASE 환경 변수가 data_db 서비스에 설정되어 있어야 함
# docker-compose.yml에서 POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB로 설정됨.
# psql은 이 환경 변수들을 자동으로 사용합니다.

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
  CREATE EXTENSION IF NOT EXISTS vector;
  CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

  -- 테스트용 출력
  \echo '🧠 vector 확장 버전:'
  SELECT extversion FROM pg_extension WHERE extname='vector';
  
  \echo '🔑 uuid-ossp 확장 버전:'
  SELECT extversion FROM pg_extension WHERE extname='uuid-ossp';

  \echo '🧪 예시 UUID (v4):'
  SELECT uuid_generate_v4();
EOSQL

echo "✅ vector 및 uuid-ossp 확장 설치 완료 (DB: $POSTGRES_DB)"