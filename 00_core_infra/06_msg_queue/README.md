# 메시지 큐 처리 전략 (msg_queue)

## 📌 목적
본 디렉토리는 초기 설계 당시 메시지 큐 시스템을 분리 운용할 가능성을 고려하여 생성되었으나,  
현재 Flogi 시스템에서는 `Celery + Redis` 기반의 비동기 작업 처리 구조로 일원화되었습니다.

> 메시지 큐는 "파이프라인 간 시간지연/의존성을 끊는 구조적 완충지"입니다.  
> 현재 Flogi의 모든 비동기 처리 요청은 Celery Task로 분산되며, Redis는 그 중개 저장소 역할을 수행합니다.

---

## ✅ 현재 채택된 구조

| 구성 요소 | 설명 |
|-----------|------|
| **Celery** | Python 기반 분산 Task Queue 프레임워크 |
| **Redis** | Celery의 Broker이자 Result Backend |
| **사용 위치** | `03_pipeline/00_celery/`, `04_mk_msg`, `06_upload` 등에서 비동기 요청 시 사용 |
| **배포 구조** | 컨테이너: `celery`, `redis` 별도 분리 / `docker-compose.pipeline.yml`에 정의 |

---

## 🧱 처리 단계 정의 (Phase Strategy)

| Phase | 구조 | 설명 |
|-------|------|------|
| Phase 0 | `BackgroundTask` (FastAPI 내장) | MVP 개발 초기단계. 단일 프로세스 동기 처리 |
| Phase 1 | `Celery + Redis` | 현재 적용 구조. 단일 Redis 기반 분산 작업 처리 |
| Phase 2 | `Redis (shard) + Celery (scale-out)` | 필요 시 Redis 다중 샤드 구성. 대용량 이벤트 처리 대응 |
| Phase 3 (예정) | Kafka or RabbitMQ 도입 | 스트리밍/순서보장/트랜잭션이 필요한 경우로 한정 |

---

## 🛠 운영 예시

### 예시: 메시지 발송 요청 (from mk_msg → upload)

```python
from celery import shared_task
from .upload import upload_to_slack

@shared_task
def enqueue_upload(user_id: str, message_data: dict):
    upload_to_slack(user_id, message_data)
