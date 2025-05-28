# worker_app.py (프로젝트 루트 또는 공용 위치에 생성)
from celery import Celery
import os

# Redis 브로커 URL 설정 (docker-compose에서 환경변수로 전달된 값 사용)
# 또는 Flogi-Web의 config.py에서 설정값 가져오기
redis_host = os.environ.get('REDIS_HOST', 'localhost')
redis_port = os.environ.get('REDIS_PORT', '6379')
broker_url = f'redis://{redis_host}:{redis_port}/0'
result_backend_url = f'redis://{redis_host}:{redis_port}/1' # 결과 저장을 위해 다른 DB 사용 가능

celery_app = Celery(
    'flogi_tasks', # 앱 이름
    broker=broker_url,
    backend=result_backend_url,
    include=[ # 여기에 각 모듈의 Celery 태스크 파일들을 문자열로 나열
        '03_describe.01_scoping.tasks', # 예시: 03_describe/01_scoping/tasks.py
        '03_describe.02_prompt_gen.tasks',# 예시: 03_describe/02_prompt_gen/tasks.py
        '04_06_LLM.tasks',                # 예시: 04_06_LLM/tasks.py
        '05_mk_msg.tasks',                # 예시: 05_mk_msg/tasks.py
        '07_upload.tasks',                # 예시: 07_upload/tasks.py
        # ... 다른 모듈의 태스크들
    ]
)

# Celery 설정 (선택적)
celery_app.conf.update(
    task_serializer='json',
    accept_content=['json'],
    result_serializer='json',
    timezone='Asia/Seoul', # 프로젝트 기본 시간대
    enable_utc=True,
    # task_track_started=True, # 작업 시작 상태 추적
    # worker_send_task_events=True, # Flower 등 모니터링 도구 위해
    # worker_prefetch_multiplier=1, # 안정성을 위해 1로 설정 (메모리 문제 발생 시)
)

# 주기적 작업 설정 (Celery Beat 사용 시)
# celery_app.conf.beat_schedule = {
#    'run-db-etl-every-monday-3am': {
#        'task': '00_DB.tasks.run_move_data_task', # 00_DB/tasks.py에 정의된 태스크 가정
#        'schedule': crontab(hour=3, minute=0, day_of_week=1), # 매주 월요일 새벽 3시
#    },
#    'cleanup-old-sessions-daily': {
#        'task': 'common_tasks.delete_expired_sessions_task', # 공용 태스크 가정
#        'schedule': crontab(hour=1, minute=0), # 매일 새벽 1시
#    }
# }

if __name__ == '__main__':
    celery_app.start()