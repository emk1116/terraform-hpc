"""SQLAlchemy setup for Aurora MySQL.

Two engines:
- `engine` (writer) — for all write operations and app queries
- `reader_engine` — for Slurm accounting read-only queries (cost rollups)

Connections are pooled; pre-ping checks for dead connections after Aurora
failover or ACU scale events.
"""

from __future__ import annotations

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from app.config import get_jobui_db_credentials, get_settings


def _build_url(host: str) -> str:
    creds = get_jobui_db_credentials()
    s = get_settings()
    return (
        f"mysql+pymysql://{creds['username']}:{creds['password']}"
        f"@{host}:{s.AURORA_PORT}/{creds['database']}?charset=utf8mb4"
    )


settings = get_settings()

engine = create_engine(
    _build_url(settings.AURORA_WRITER_ENDPOINT),
    pool_pre_ping=True,
    pool_size=5,
    max_overflow=10,
    pool_recycle=300,
    echo=False,
)

reader_engine = create_engine(
    _build_url(settings.AURORA_READER_ENDPOINT),
    pool_pre_ping=True,
    pool_size=3,
    max_overflow=5,
    pool_recycle=300,
    echo=False,
)

SessionLocal = sessionmaker(bind=engine, autoflush=False, autocommit=False)
ReaderSessionLocal = sessionmaker(bind=reader_engine, autoflush=False, autocommit=False)


class Base(DeclarativeBase):
    pass


def get_db():
    """FastAPI dependency — yields a session, closes on request end."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def get_reader_db():
    db = ReaderSessionLocal()
    try:
        yield db
    finally:
        db.close()
