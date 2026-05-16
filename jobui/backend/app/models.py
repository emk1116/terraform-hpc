"""SQLAlchemy ORM models for the jobui database.

Schema matches the design from the Aurora planning turn:
- app_users: team members with roles, budgets, H100 approval
- models: ECR-backed inference models with GPU memory + allowlist
- uploads: multipart S3 upload tracking
- jobs: job submissions with Slurm integration
- monthly_spend: rollup for budget enforcement
- audit_log: action log for compliance
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime
from decimal import Decimal

from sqlalchemy import (
    JSON,
    BigInteger,
    Boolean,
    CHAR,
    DECIMAL,
    DateTime,
    Enum,
    ForeignKey,
    Index,
    Integer,
    SmallInteger,
    String,
    Text,
    func,
)
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


class UserRole(str, enum.Enum):
    member = "member"
    admin = "admin"


class JobStatus(str, enum.Enum):
    submitted = "submitted"
    pending = "pending"
    running = "running"
    completed = "completed"
    failed = "failed"
    cancelled = "cancelled"


class UploadStatus(str, enum.Enum):
    initiated = "initiated"
    uploading = "uploading"
    completed = "completed"
    aborted = "aborted"
    failed = "failed"


class AppUser(Base):
    __tablename__ = "app_users"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(64), unique=True, nullable=False, index=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, nullable=False)
    display_name: Mapped[str | None] = mapped_column(String(128))
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    role: Mapped[UserRole] = mapped_column(Enum(UserRole), default=UserRole.member, nullable=False)
    slurm_account: Mapped[str] = mapped_column(String(64), nullable=False, index=True)
    h100_approved: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    monthly_budget_usd: Mapped[Decimal] = mapped_column(
        DECIMAL(10, 2), default=Decimal("500.00"), nullable=False
    )
    must_change_password: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp(), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime,
        server_default=func.current_timestamp(),
        onupdate=func.current_timestamp(),
        nullable=False,
    )

    jobs: Mapped[list["Job"]] = relationship(back_populates="user")
    uploads: Mapped[list["Upload"]] = relationship(back_populates="user")


class Model(Base):
    __tablename__ = "models"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    model_key: Mapped[str] = mapped_column(String(128), unique=True, nullable=False)
    display_name: Mapped[str] = mapped_column(String(255), nullable=False)
    description: Mapped[str | None] = mapped_column(Text)

    ecr_uri: Mapped[str] = mapped_column(String(512), nullable=False)
    weights_path: Mapped[str | None] = mapped_column(String(512))
    weights_arg: Mapped[str] = mapped_column(String(128), default="--weights")
    input_arg: Mapped[str] = mapped_column(String(128), default="--input")
    output_arg: Mapped[str] = mapped_column(String(128), default="--output")
    extra_args: Mapped[str | None] = mapped_column(Text)

    gpu_min_memory_gb: Mapped[int] = mapped_column(SmallInteger, nullable=False)
    allowed_gpus: Mapped[list] = mapped_column(JSON, nullable=False)
    default_runtime_hours: Mapped[int] = mapped_column(SmallInteger, default=4, nullable=False)
    max_runtime_hours: Mapped[int] = mapped_column(SmallInteger, default=24, nullable=False)

    is_active: Mapped[bool] = mapped_column(Boolean, default=True, nullable=False)
    registered_by: Mapped[int | None] = mapped_column(
        BigInteger, ForeignKey("app_users.id", ondelete="SET NULL")
    )
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp(), nullable=False
    )


class Upload(Base):
    __tablename__ = "uploads"

    id: Mapped[str] = mapped_column(CHAR(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    user_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("app_users.id"), nullable=False
    )
    filename: Mapped[str] = mapped_column(String(512), nullable=False)
    size_bytes: Mapped[int] = mapped_column(BigInteger, nullable=False)
    s3_key: Mapped[str] = mapped_column(String(1024), nullable=False)
    s3_upload_id: Mapped[str | None] = mapped_column(String(256))
    status: Mapped[UploadStatus] = mapped_column(
        Enum(UploadStatus), default=UploadStatus.initiated, nullable=False
    )
    content_sha256: Mapped[str | None] = mapped_column(CHAR(64))
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp(), nullable=False
    )
    completed_at: Mapped[datetime | None] = mapped_column(DateTime)

    user: Mapped["AppUser"] = relationship(back_populates="uploads")

    __table_args__ = (Index("idx_user_status", "user_id", "status"),)


class Job(Base):
    __tablename__ = "jobs"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("app_users.id"), nullable=False
    )
    model_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("models.id"), nullable=False)
    upload_id: Mapped[str] = mapped_column(CHAR(36), ForeignKey("uploads.id"), nullable=False)

    gpu_family: Mapped[str] = mapped_column(String(32), nullable=False)
    gpu_count: Mapped[int] = mapped_column(SmallInteger, default=1, nullable=False)
    requested_hours: Mapped[int] = mapped_column(SmallInteger, nullable=False)

    slurm_job_id: Mapped[int | None] = mapped_column(BigInteger, index=True)
    slurm_account: Mapped[str] = mapped_column(String(64), nullable=False)
    partition: Mapped[str] = mapped_column(String(64), nullable=False)

    status: Mapped[JobStatus] = mapped_column(
        Enum(JobStatus), default=JobStatus.submitted, nullable=False, index=True
    )

    estimated_cost_usd: Mapped[Decimal] = mapped_column(DECIMAL(10, 4), nullable=False)
    actual_cost_usd: Mapped[Decimal | None] = mapped_column(DECIMAL(10, 4))

    result_s3_prefix: Mapped[str | None] = mapped_column(String(1024))
    extra_args: Mapped[str | None] = mapped_column(Text)

    submitted_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp(), nullable=False
    )
    started_at: Mapped[datetime | None] = mapped_column(DateTime)
    ended_at: Mapped[datetime | None] = mapped_column(DateTime)

    user: Mapped["AppUser"] = relationship(back_populates="jobs")
    model: Mapped["Model"] = relationship()
    upload: Mapped["Upload"] = relationship()

    __table_args__ = (Index("idx_user_submitted", "user_id", "submitted_at"),)


class MonthlySpend(Base):
    __tablename__ = "monthly_spend"

    user_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("app_users.id"), primary_key=True
    )
    year_month: Mapped[str] = mapped_column(CHAR(7), primary_key=True)
    spend_usd: Mapped[Decimal] = mapped_column(DECIMAL(10, 2), default=Decimal("0"), nullable=False)
    job_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    gpu_hours: Mapped[Decimal] = mapped_column(
        DECIMAL(10, 2), default=Decimal("0"), nullable=False
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime,
        server_default=func.current_timestamp(),
        onupdate=func.current_timestamp(),
        nullable=False,
    )


class AuditLog(Base):
    __tablename__ = "audit_log"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    user_id: Mapped[int | None] = mapped_column(
        BigInteger, ForeignKey("app_users.id", ondelete="SET NULL")
    )
    action: Mapped[str] = mapped_column(String(64), nullable=False)
    target_type: Mapped[str | None] = mapped_column(String(64))
    target_id: Mapped[str | None] = mapped_column(String(128))
    details: Mapped[dict | None] = mapped_column(JSON)
    ip_address: Mapped[str | None] = mapped_column(String(45))
    created_at: Mapped[datetime] = mapped_column(
        DateTime, server_default=func.current_timestamp(), nullable=False, index=True
    )
