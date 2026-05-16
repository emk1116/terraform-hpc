"""FastAPI application entrypoint."""

from __future__ import annotations

import logging
from pathlib import Path

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles

from app.config import get_settings
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

# CORS — ALB terminates TLS; we don't expect cross-origin, but allow for dev
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
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
    return {"status": "ok", "team": get_settings().TEAM_NAME}


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
