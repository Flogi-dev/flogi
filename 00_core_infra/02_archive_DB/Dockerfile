# 00_core_infra/02_archive_DB/Dockerfile
FROM postgres:16

# 필요한 경우 PostgreSQL 설정을 복사할 수 있습니다.
# COPY postgresql.conf /etc/postgresql/postgresql.conf

# 초기화 스크립트를 복사합니다.
COPY ./init-db-extensions.sh /docker-entrypoint-initdb.d/
# (Archive DB는 pgvector가 명시적으로 필요하지 않다면 postgres:16 이미지를 사용하고,
# 만약 archive DB에도 vector 타입 데이터가 저장된다면 pgvector/pgvector:pg16 이미지를 사용해야 합니다.
# structure.txt 상으로는 04_elements_embeddings.sql 등이 archive_DB에도 있으므로 [cite: 41]
# pgvector 이미지를 사용하는 것이 일관성 있을 수 있습니다. 아래 init-db-extensions.sh도 이를 가정하고 작성합니다.)

# 만약 pgvector가 필요하다면:
# FROM pgvector/pgvector:pg16
# COPY ./init-db-extensions.sh /docker-entrypoint-initdb.d/

EXPOSE 5432