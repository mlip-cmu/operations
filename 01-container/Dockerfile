# syntax=docker/dockerfile:1

# Base: a pinned Python image (tag for people, digest for machines) and a pinned uv
FROM python:3.13-slim@sha256:bf44cdfcb76cd3b41e879bc058fc37ec5872002ccfde7fcb765e218cde0cd79c AS base
COPY --from=astral/uv:0.11.33 /uv /usr/local/bin/uv
ENV UV_COMPILE_BYTECODE=1 UV_LINK_MODE=copy UV_PYTHON_DOWNLOADS=never
WORKDIR /app

# Stage 1: download the pretrained model and convert it to ONNX (needs PyTorch)
FROM base AS model
COPY pyproject.toml uv.lock ./
RUN uv sync --locked --only-group export
COPY export_model.py ./
RUN uv run --no-sync python export_model.py /model

# Stage 2: the service; only the runtime dependencies and the converted model
FROM base AS runtime
COPY pyproject.toml uv.lock ./
RUN uv sync --locked
COPY --from=model /model /app/model
COPY spamfilter ./spamfilter
RUN useradd --system --no-create-home app
USER app
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION} PATH="/app/.venv/bin:${PATH}"
EXPOSE 8000
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"]
CMD ["uvicorn", "spamfilter.app:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
