"""Valkey (ElastiCache Serverless) client — TLS, Redis-wire-protocol compatible."""

from __future__ import annotations

import json
from functools import lru_cache

from valkey import Valkey

from app.config import get_settings


@lru_cache
def get_cache() -> Valkey:
    s = get_settings()
    return Valkey(
        host=s.VALKEY_ENDPOINT,
        port=s.VALKEY_PORT,
        ssl=True,
        decode_responses=True,
        socket_connect_timeout=5,
        socket_timeout=5,
    )


# ---------------------------------------------------------------------------
# Helpers — hide the JSON serialization
# ---------------------------------------------------------------------------

def cache_set(key: str, value, ttl_seconds: int = 300):
    get_cache().setex(key, ttl_seconds, json.dumps(value, default=str))


def cache_get(key: str):
    raw = get_cache().get(key)
    return json.loads(raw) if raw else None


def cache_delete(key: str):
    get_cache().delete(key)


def rate_limit_check(key: str, limit: int, window_seconds: int) -> bool:
    """Fixed-window rate limiter. Returns True if under limit, False if exceeded."""
    c = get_cache()
    current = c.incr(key)
    if current == 1:
        c.expire(key, window_seconds)
    return current <= limit
