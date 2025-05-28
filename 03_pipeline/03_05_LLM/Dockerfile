# Web/Dockerfile
FROM python:3.13-slim

ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1

WORKDIR /app # 컨테이너 내 작업 디렉토리

# 프로젝트 루트의 poetry.lock, pyproject.toml을 사용하기 위해 먼저 복사
# 빌드 컨텍스트가 /Web 이므로, 상위 디렉토리의 파일을 참조하려면 빌드 시 --build-arg 등으로 경로 전달 또는
# docker-compose.yml에서 build.context를 프로젝트 루트로 하고 dockerfile 경로를 Web/Dockerfile로 지정
# 여기서는 docker-compose.yml에서 context를 프로젝트 루트로 설정하는 방식을 가정합니다.
COPY poetry.lock pyproject.toml /app/

RUN pip install --no-cache-dir poetry && \
    poetry config virtualenvs.create false && \
    poetry install --no-interaction --no-ansi --no-root
    # 필요한 경우 --only main 등 의존성 그룹 지정

# Web 디렉토리의 모든 코드를 이미지의 /app/Web 으로 복사
COPY ./Web /app/Web
# flogi 디렉토리의 모든 코드를 이미지의 /app/flogi 로 복사
COPY ./flogi /app/flogi

# Web 디렉토리를 작업 디렉토리로 변경 (server.py 실행 기준)
WORKDIR /app/Web

EXPOSE 8000
CMD ["poetry", "run", "uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8000"]