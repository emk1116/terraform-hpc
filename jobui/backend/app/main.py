from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from contextlib import asynccontextmanager

from app.config import get_settings
from app.database import init_db
from app.routers import auth, files, jobs
from app.services import slurm_service
from app.utils.logging import get_logger

logger = get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    logger.info("Starting HPC Platform API", extra={"db_path": settings.db_path})
    try:
        init_db(settings.db_path, settings.default_users)
        logger.info("Database initialized successfully")
    except Exception as e:
        logger.error("Database initialization failed", extra={"error": str(e)})
        raise
    yield
    logger.info("Shutting down HPC Platform API")


app = FastAPI(
    title="Titan HPC Platform API",
    description="Enterprise HPC job management API with Slurm and S3 integration",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth.router)
app.include_router(files.router)
app.include_router(jobs.router)


@app.get("/health", tags=["health"])
async def health_check():
    slurm_available = slurm_service.is_available()
    settings = get_settings()
    return {
        "status": "ok",
        "slurm_available": slurm_available,
        "s3_configured": bool(settings.s3_bucket),
        "version": "1.0.0",
    }
