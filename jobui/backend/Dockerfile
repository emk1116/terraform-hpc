FROM python:3.11-slim AS builder

WORKDIR /build
COPY pyproject.toml ./

RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir --prefix=/install .

# ---------------------------------------------------------------------------

FROM python:3.11-slim

# Slurm client binaries (the host mounts /opt/slurm; we ensure libs are present)
RUN apt-get update && apt-get install -y --no-install-recommends \
      libmunge2 \
      libmariadb3 \
      ca-certificates \
      curl \
      jq \
      awscli \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /install /usr/local

WORKDIR /app
COPY app/ ./app/
COPY alembic/ ./alembic/
COPY alembic.ini ./

ENV PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app \
    PATH="/opt/slurm/bin:/opt/slurm/sbin:/usr/local/bin:/usr/bin:/bin"

EXPOSE 8000

# Startup: run migrations, bootstrap admin, start uvicorn
CMD ["sh", "-c", "\
  alembic upgrade head && \
  python -m app.scripts.bootstrap && \
  uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 2 \
"]
