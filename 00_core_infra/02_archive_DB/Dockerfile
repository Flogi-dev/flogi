# 베이스 이미지: PostgreSQL + pgvector 확장 포함
FROM ankane/pgvector:latest

# uuid-ossp 등 추가 확장을 위해 postgresql-contrib 설치
RUN apt-get update && apt-get install -y postgresql-contrib && rm -rf /var/lib/apt/lists/*

# 초기화 스크립트 복사
# 이 스크립트는 컨테이너가 처음 시작될 때 /docker-entrypoint-initdb.d/ 디렉토리 내에서 자동으로 실행됩니다.
COPY init-db-extensions.sh /docker-entrypoint-initdb.d/init-db-extensions.sh

# 스크립트에 실행 권한 부여 (선택적, 보통 기본적으로 부여됨)
RUN chmod +x /docker-entrypoint-initdb.d/init-db-extensions.sh