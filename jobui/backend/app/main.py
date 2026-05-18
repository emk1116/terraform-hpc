"""FastAPI application entrypoint."""

from __future__ import annotations

import logging
import subprocess
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse
from fastapi.staticfiles import StaticFiles

from app.config import get_settings
from app.database import engine
from app.routers import auth, gpus, jobs, models, uploads, users

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logger = logging.getLogger(__name__)

app = FastAPI(
    title="Titan HPC jobui",
    version="0.1.0",
    docs_url="/api/docs",
    openapi_url="/api/openapi.json",
)

# CORS — JWT tokens travel in the Authorization header, not cookies, so
# allow_credentials is not needed. Restrict origins in production by setting
# CORS_ALLOWED_ORIGINS env var (comma-separated list).
import os as _os
_cors_origins = [o.strip() for o in _os.environ.get("CORS_ALLOWED_ORIGINS", "*").split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_credentials=False,
    allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

# Routers
app.include_router(auth.router)
app.include_router(users.router)
app.include_router(models.router)
app.include_router(gpus.router)
app.include_router(uploads.router)
app.include_router(jobs.router)


@app.get("/api/health")
def health():
    checks: dict[str, str] = {}

    # Aurora
    try:
        with engine.connect() as conn:
            conn.exec_driver_sql("SELECT 1")
        checks["aurora"] = "ok"
    except Exception as exc:
        checks["aurora"] = f"error: {exc}"

    # Slurm (scontrol ping)
    try:
        r = subprocess.run(
            ["scontrol", "ping"],
            capture_output=True, text=True, timeout=5,
        )
        checks["slurm"] = "ok" if r.returncode == 0 else f"error: {r.stderr.strip()}"
    except Exception as exc:
        checks["slurm"] = f"error: {exc}"

    ok = all(v == "ok" for v in checks.values())
    status_code = 200 if ok else 503
    return JSONResponse(
        status_code=status_code,
        content={"status": "ok" if ok else "degraded", "team": get_settings().TEAM_NAME, "checks": checks},
    )


# ---------------------------------------------------------------------------
# Static SPA — the Dockerfile copies the React build into /app/static
# nginx handles the / path in production; this is the fallback for dev.
# ---------------------------------------------------------------------------

STATIC_DIR = Path("/app/static")
if STATIC_DIR.exists():
    app.mount("/assets", StaticFiles(directory=STATIC_DIR / "assets"), name="assets")

    @app.get("/{full_path:path}")
    def spa(full_path: str):
        # API calls go through routers above; this is the SPA fallback
        index = STATIC_DIR / "index.html"
        if index.exists():
            return FileResponse(index)
        return {"error": "static not built"}
