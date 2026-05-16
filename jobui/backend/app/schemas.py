"""Pydantic schemas — request/response shapes for the API."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, EmailStr, Field


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

class LoginRequest(BaseModel):
    username: str
    password: str


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    must_change_password: bool = False


class ChangePasswordRequest(BaseModel):
    current_password: str
    new_password: str = Field(min_length=12)


# ---------------------------------------------------------------------------
# Users
# ---------------------------------------------------------------------------

class UserOut(BaseModel):
    id: int
    username: str
    email: EmailStr
    display_name: str | None
    role: str
    slurm_account: str
    h100_approved: bool
    monthly_budget_usd: Decimal
    is_active: bool
    must_change_password: bool

    class Config:
        from_attributes = True


class UserCreate(BaseModel):
    username: str = Field(min_length=3, max_length=64)
    email: EmailStr
    display_name: str | None = None
    role: str = "member"
    h100_approved: bool = False
    monthly_budget_usd: Decimal = Decimal("500")
    temp_password: str = Field(min_length=12)


class UserUpdate(BaseModel):
    display_name: str | None = None
    role: str | None = None
    h100_approved: bool | None = None
    monthly_budget_usd: Decimal | None = None
    is_active: bool | None = None


# ---------------------------------------------------------------------------
# Models catalog
# ---------------------------------------------------------------------------

class ModelOut(BaseModel):
    id: int
    model_key: str
    display_name: str
    description: str | None
    ecr_uri: str
    weights_path: str | None
    gpu_min_memory_gb: int
    allowed_gpus: list[str]
    default_runtime_hours: int
    max_runtime_hours: int
    is_active: bool

    class Config:
        from_attributes = True


class ModelCreate(BaseModel):
    model_key: str = Field(min_length=3, max_length=128)
    display_name: str
    description: str | None = None
    ecr_uri: str
    weights_path: str | None = None
    weights_arg: str = "--weights"
    input_arg: str = "--input"
    output_arg: str = "--output"
    extra_args: str | None = None
    gpu_min_memory_gb: int = Field(ge=1, le=640)
    allowed_gpus: list[str]
    default_runtime_hours: int = 4
    max_runtime_hours: int = 24


# ---------------------------------------------------------------------------
# GPUs
# ---------------------------------------------------------------------------

class GpuOption(BaseModel):
    family: str
    display_name: str
    partition: str
    instance_type: str
    gpu_memory_gb: int
    gpus_per_node: int
    hourly_cost_usd: float
    requires_approval: bool


# ---------------------------------------------------------------------------
# Uploads
# ---------------------------------------------------------------------------

class UploadInitRequest(BaseModel):
    filename: str
    size_bytes: int = Field(ge=1, le=10 * 1024 * 1024 * 1024)  # 10 GB max


class UploadPartUrl(BaseModel):
    part_number: int
    url: str


class UploadInitResponse(BaseModel):
    upload_id: str  # our UUID
    s3_upload_id: str
    s3_key: str
    part_size_bytes: int
    part_urls: list[UploadPartUrl]


class UploadCompletePart(BaseModel):
    PartNumber: int
    ETag: str


class UploadCompleteRequest(BaseModel):
    parts: list[UploadCompletePart]


class UploadOut(BaseModel):
    id: str
    filename: str
    size_bytes: int
    status: str
    created_at: datetime
    completed_at: datetime | None

    class Config:
        from_attributes = True


# ---------------------------------------------------------------------------
# Jobs
# ---------------------------------------------------------------------------

class JobSubmitRequest(BaseModel):
    upload_id: str
    model_id: int
    gpu_family: str
    gpu_count: int = 1
    requested_hours: int = Field(ge=1, le=48)
    extra_args: str | None = None


class JobSubmitResponse(BaseModel):
    job_id: int  # our jobs.id
    slurm_job_id: int
    estimated_cost_usd: Decimal
    partition: str


class JobOut(BaseModel):
    id: int
    slurm_job_id: int | None
    user_id: int
    model_id: int
    gpu_family: str
    gpu_count: int
    partition: str
    status: str
    estimated_cost_usd: Decimal
    actual_cost_usd: Decimal | None
    requested_hours: int
    submitted_at: datetime
    started_at: datetime | None
    ended_at: datetime | None
    result_s3_prefix: str | None

    class Config:
        from_attributes = True


class JobDetail(JobOut):
    slurm_state: str | None = None
    slurm_reason: str | None = None
    slurm_node: str | None = None
    log_tail: str | None = None
    result_files: list[dict] | None = None


class CostPreviewRequest(BaseModel):
    gpu_family: str
    hours: int


class CostPreviewResponse(BaseModel):
    gpu_family: str
    hours: int
    hourly_rate_usd: float
    estimated_cost_usd: Decimal
    remaining_budget_usd: Decimal
    will_exceed_budget: bool
