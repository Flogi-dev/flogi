# `flogi-db-live` - Live PostgreSQL Database README

## 1. 개요 (Overview)
이 컨테이너는 Flogi 서비스의 주요 운영 데이터를 저장하는 PostgreSQL 데이터베이스입니다. 사용자 정보, 저장소 메타데이터, 실시간 커밋 생성 데이터, LLM 요청 로그, 요금제 정보 등 대부분의 활성 데이터를 관리합니다. pgvector 확장을 통해 임베딩 벡터 저장 및 검색 기능을 제공합니다.

## 2. 주요 기술 스택 (Key Technologies)
* PostgreSQL 16
* pgvector 0.8 (HNSW)
* Docker

## 3. 환경 변수 및 설정 (Environment Variables & Configuration)
* `POSTGRES_USER`: PostgreSQL 사용자 (예: `flogi_user`)
* `POSTGRES_PASSWORD`: PostgreSQL 사용자 비밀번호
* `POSTGRES_DB`: 데이터베이스 이름 (예: `flogi_comfort_commit`)
* `PGDATA`: PostgreSQL 데이터 디렉토리 (컨테이너 내부 경로)
* **스키마 초기화**: 컨테이너 시작 시 `/docker-entrypoint-initdb.d/` 경로의 `.sql` 및 `.sh` 파일들이 실행되어 스키마와 확장을 초기화합니다.
    * `00_core_infra/01_live_DB/init-db-extensions.sh`: `uuid-ossp`, `pgvector` 등 확장 활성화.
    * `00_core_infra/01_live_DB/01_user/` 등 하위 SQL 파일들: 테이블, 타입, 함수 등 스키마 정의.

## 4. 빌드 및 실행 (Build & Run)
**빌드:**
```bash
docker build -t flogi-db-live ./00_core_infra/01_live_DB/