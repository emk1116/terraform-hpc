from pydantic import BaseModel, Field
from typing import Optional, List
from datetime import datetime


class Token(BaseModel):
    access_token: str
    token_type: str = "bearer"


class LoginRequest(BaseModel):
    username: str
    password: str


class UserResponse(BaseModel):
    id: str
    username: str
    cluster_user: str
    is_admin: bool


class JobSubmitRequest(BaseModel):
    name: str = Field(..., min_length=1, max_length=64, pattern=r'^[a-zA-Z0-9_-]+$')
    input_prefix: str = Field(..., description="S3 key prefix under input/{user_id}/")
    command: str = Field(default="echo 'No command specified' > output/result.txt")
    cpus: int = Field(default=1, ge=1, le=8)
    memory_mb: int = Field(default=800, ge=256, le=7500)
    time_limit: str = Field(default="01:00:00", pattern=r'^\d{2}:\d{2}:\d{2}$')


class JobResponse(BaseModel):
    id: str
    slurm_job_id: Optional[int]
    user_id: str
    cluster_user: str
    name: str
    status: str
    input_prefix: str
    cpus: int
    memory_mb: int
    time_limit: str
    command: str
    created_at: str
    updated_at: str
    error_message: Optional[str]


class FileInfo(BaseModel):
    key: str
    size: int
    last_modified: str
    filename: str


class ResultFile(BaseModel):
    filename: str
    key: str
    size: int
    presigned_url: str


class UploadResponse(BaseModel):
    key: str
    filename: str
    size: int
    message: str


class LogResponse(BaseModel):
    job_id: str
    log: str
    available: bool
