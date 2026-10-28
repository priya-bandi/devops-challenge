# syntax=docker/dockerfile:1
# Shared image for vision_api and inference_worker (stdlib-only Python apps).

ARG PYTHON_IMAGE=python:3.11-slim-bookworm

# ---------- Stage 1: assemble the app with correct permissions ----------
FROM ${PYTHON_IMAGE} AS build
WORKDIR /src
COPY vision_api/ vision_api/
COPY inference_worker/ inference_worker/
COPY healthcheck.py ./
COPY models/ models/
# Root-owned and read-only for everyone: the runtime user can read but never modify code or models.
RUN find . -type d -exec chmod 0755 {} + \
 && find . -type f -exec chmod 0644 {} + \
 && python -m compileall -q vision_api inference_worker healthcheck.py

# ---------- Stage 2: minimal runtime ----------
FROM ${PYTHON_IMAGE}
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    TRT_CACHE_DIR=/tmp/trt_cache
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app
WORKDIR /app
COPY --from=build /src/ /app/
USER 10001:10001
EXPOSE 8000 9000
CMD ["python", "vision_api/app.py"]
