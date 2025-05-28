# `Flogi_Redis` - Redis In-Memory Cache & Message Broker README

## 1. 개요 (Overview)
이 컨테이너는 Flogi 서비스의 인메모리 캐싱, Celery를 위한 메시지 브로커, 그리고 API 키 등 중요 설정 값 참조 지점 역할을 수행하는 Redis 인스턴스입니다. 빠른 데이터 접근과 비동기 작업 큐 관리를 담당합니다.

**주의**: API 키 등 매우 민감한 정보는 Redis에 저장하기 전에 애플리케이션 레벨에서 암호화하는 것을 강력히 권장합니다.

## 2. 주요 기술 스택 (Key Technologies)
* Redis 7.2.4-alpine
* Docker

## 3. 환경 변수 및 설정 (Environment Variables & Configuration)
* **`.env` 파일 참조**: 이 컨테이너는 `./.env` 파일 (또는 `docker-compose.yml`에 명시된 `env_file` 경로)을 통해 환경 변수를 주입받습니다.
    * `REDIS_PASSWORD`: Redis 접속 시 사용될 비밀번호입니다. (필수 설정 권장)
* **설정 파일**: `/etc/redis/redis.conf` (컨테이너 내부). 호스트의 `00_core_infra/03_redis/redis.conf` 파일이 `Dockerfile`에 의해 이 경로로 복사되어 사용됩니다. 주요 설정은 다음과 같습니다:
    * `appendonly yes`: AOF(Append Only File) 영속성 활성화.
    * `dir /data`: 데이터 저장 디렉토리.
    * (기타 필요한 성능 및 보안 관련 설정)

## 4. 빌드 및 실행 (Build & Run)
**빌드:**
```bash
# 00_core_infra 디렉토리에서 실행
docker-compose -f docker-compose.infra.yml build flogi_redis
# 또는 개별 빌드
# docker build -t flogi-redis ./00_core_infra/03_redis/