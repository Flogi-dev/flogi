# 00_core_infra/01_live_DB/Dockerfile
FROM pgvector/pgvector:pg16

# 필요한 경우 PostgreSQL 설정을 복사할 수 있습니다.
# COPY postgresql.conf /etc/postgresql/postgresql.conf

# 초기화 스크립트를 복사합니다.
# 이 스크립트들은 /docker-entrypoint-initdb.d/ 에 위치하여
# 데이터베이스가 처음 생성될 때 자동으로 실행됩니다.
COPY ./init-db-extensions.sh /docker-entrypoint-initdb.d/
# 여기에 스키마 .sql 파일들을 복사하는 명령도 추가될 수 있습니다.
# 예: COPY ./01_user/ /docker-entrypoint-initdb.d/01_user/
# (단, structure.txt 에 따르면 스키마 파일들은 docker-compose.yml 에서 볼륨 마운트 될 수 있음)

# 기본 포트는 5432이며, docker-compose.yml 에서 매핑합니다.
EXPOSE 5432