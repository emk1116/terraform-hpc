"""Configuration for the jobui backend.

All runtime config comes from environment variables set by the head node's
user-data. Secrets (DB password, JWT signing key) are fetched from Secrets
Manager at startup via the instance profile.
"""

from __future__ import annotations

import json
from functools import lru_cache

import boto3
from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=None, case_sensitive=True)

    # AWS
    AWS_REGION: str = "us-east-1"
    TEAM_NAME: str = "alpha"
    S3_BUCKET: str
    ECR_REGISTRY: str

    # Aurora
    AURORA_WRITER_ENDPOINT: str
    AURORA_READER_ENDPOINT: str
    AURORA_JOBUI_SECRET_ARN: str
    AURORA_PORT: int = 3306

    # Valkey
    VALKEY_ENDPOINT: str
    VALKEY_PORT: int = 6379

    # Auth
    JWT_SECRET_ARN: str
    JWT_ALGORITHM: str = "HS256"
    JWT_EXPIRY_HOURS: int = 8

    # Bootstrap
    ADMIN_TEMP_SECRET_ARN: str
    USERS_SEED_PARAMETER: str
    ADMIN_EMAIL: str

    # Defaults
    DEFAULT_USER_BUDGET: float = 500.0

    # GPU spec — JSON string, parsed on first access
    GPU_FAMILY_SPEC: str = "{}"

    # Slurm binaries — path is set by Docker image
    SLURM_BIN_DIR: str = "/opt/slurm/bin"


@lru_cache
def get_settings() -> Settings:
    return Settings()


# ---------------------------------------------------------------------------
# Secrets helpers — thin wrappers around Secrets Manager
# ---------------------------------------------------------------------------

_sm_client = None


def _sm():
    global _sm_client
    if _sm_client is None:
        _sm_client = boto3.client("secretsmanager", region_name=get_settings().AWS_REGION)
    return _sm_client


@lru_cache
def get_jwt_secret() -> str:
    s = get_settings()
    return _sm().get_secret_value(SecretId=s.JWT_SECRET_ARN)["SecretString"]


@lru_cache
def get_jobui_db_credentials() -> dict:
    s = get_settings()
    raw = _sm().get_secret_value(SecretId=s.AURORA_JOBUI_SECRET_ARN)["SecretString"]
    return json.loads(raw)


@lru_cache
def get_admin_temp_password() -> str:
    s = get_settings()
    return _sm().get_secret_value(SecretId=s.ADMIN_TEMP_SECRET_ARN)["SecretString"]


@lru_cache
def get_users_seed() -> dict:
    """Loads the team members seed from SSM Parameter Store."""
    s = get_settings()
    ssm = boto3.client("ssm", region_name=s.AWS_REGION)
    raw = ssm.get_parameter(Name=s.USERS_SEED_PARAMETER, WithDecryption=True)
    return json.loads(raw["Parameter"]["Value"])


@lru_cache
def get_gpu_spec() -> dict:
    return json.loads(get_settings().GPU_FAMILY_SPEC or "{}")
