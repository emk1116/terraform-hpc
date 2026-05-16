"""initial schema

Revision ID: 0001_initial
Revises:
Create Date: 2026-04-17

"""
from alembic import op
import sqlalchemy as sa


revision = "0001_initial"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    # app_users
    op.create_table(
        "app_users",
        sa.Column("id", sa.BigInteger(), autoincrement=True, primary_key=True),
        sa.Column("username", sa.String(64), nullable=False),
        sa.Column("email", sa.String(255), nullable=False),
        sa.Column("display_name", sa.String(128), nullable=True),
        sa.Column("password_hash", sa.String(255), nullable=False),
        sa.Column(
            "role", sa.Enum("member", "admin", name="userrole"),
            nullable=False, server_default="member",
        ),
        sa.Column("slurm_account", sa.String(64), nullable=False),
        sa.Column("h100_approved", sa.Boolean(), nullable=False, server_default="0"),
        sa.Column(
            "monthly_budget_usd", sa.DECIMAL(10, 2),
            nullable=False, server_default="500.00",
        ),
        sa.Column("must_change_password", sa.Boolean(), nullable=False, server_default="1"),
        sa.Column("is_active", sa.Boolean(), nullable=False, server_default="1"),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
        sa.Column("updated_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
        sa.UniqueConstraint("username"),
        sa.UniqueConstraint("email"),
    )
    op.create_index("idx_users_username", "app_users", ["username"])
    op.create_index("idx_users_slurm_account", "app_users", ["slurm_account"])

    # models
    op.create_table(
        "models",
        sa.Column("id", sa.BigInteger(), autoincrement=True, primary_key=True),
        sa.Column("model_key", sa.String(128), nullable=False),
        sa.Column("display_name", sa.String(255), nullable=False),
        sa.Column("description", sa.Text(), nullable=True),
        sa.Column("ecr_uri", sa.String(512), nullable=False),
        sa.Column("weights_path", sa.String(512), nullable=True),
        sa.Column("weights_arg", sa.String(128), server_default="--weights"),
        sa.Column("input_arg", sa.String(128), server_default="--input"),
        sa.Column("output_arg", sa.String(128), server_default="--output"),
        sa.Column("extra_args", sa.Text(), nullable=True),
        sa.Column("gpu_min_memory_gb", sa.SmallInteger(), nullable=False),
        sa.Column("allowed_gpus", sa.JSON(), nullable=False),
        sa.Column("default_runtime_hours", sa.SmallInteger(), server_default="4"),
        sa.Column("max_runtime_hours", sa.SmallInteger(), server_default="24"),
        sa.Column("is_active", sa.Boolean(), server_default="1"),
        sa.Column("registered_by", sa.BigInteger(), sa.ForeignKey("app_users.id", ondelete="SET NULL")),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
        sa.UniqueConstraint("model_key"),
    )

    # uploads
    op.create_table(
        "uploads",
        sa.Column("id", sa.CHAR(36), primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("app_users.id"), nullable=False),
        sa.Column("filename", sa.String(512), nullable=False),
        sa.Column("size_bytes", sa.BigInteger(), nullable=False),
        sa.Column("s3_key", sa.String(1024), nullable=False),
        sa.Column("s3_upload_id", sa.String(256), nullable=True),
        sa.Column(
            "status",
            sa.Enum("initiated", "uploading", "completed", "aborted", "failed",
                    name="uploadstatus"),
            nullable=False, server_default="initiated",
        ),
        sa.Column("content_sha256", sa.CHAR(64), nullable=True),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
        sa.Column("completed_at", sa.DateTime(), nullable=True),
    )
    op.create_index("idx_user_status", "uploads", ["user_id", "status"])

    # jobs
    op.create_table(
        "jobs",
        sa.Column("id", sa.BigInteger(), autoincrement=True, primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("app_users.id"), nullable=False),
        sa.Column("model_id", sa.BigInteger(), sa.ForeignKey("models.id"), nullable=False),
        sa.Column("upload_id", sa.CHAR(36), sa.ForeignKey("uploads.id"), nullable=False),
        sa.Column("gpu_family", sa.String(32), nullable=False),
        sa.Column("gpu_count", sa.SmallInteger(), server_default="1"),
        sa.Column("requested_hours", sa.SmallInteger(), nullable=False),
        sa.Column("slurm_job_id", sa.BigInteger(), nullable=True),
        sa.Column("slurm_account", sa.String(64), nullable=False),
        sa.Column("partition", sa.String(64), nullable=False),
        sa.Column(
            "status",
            sa.Enum("submitted", "pending", "running", "completed", "failed",
                    "cancelled", name="jobstatus"),
            nullable=False, server_default="submitted",
        ),
        sa.Column("estimated_cost_usd", sa.DECIMAL(10, 4), nullable=False),
        sa.Column("actual_cost_usd", sa.DECIMAL(10, 4), nullable=True),
        sa.Column("result_s3_prefix", sa.String(1024), nullable=True),
        sa.Column("extra_args", sa.Text(), nullable=True),
        sa.Column("submitted_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
        sa.Column("started_at", sa.DateTime(), nullable=True),
        sa.Column("ended_at", sa.DateTime(), nullable=True),
    )
    op.create_index("idx_jobs_slurm", "jobs", ["slurm_job_id"])
    op.create_index("idx_jobs_user_submitted", "jobs", ["user_id", "submitted_at"])
    op.create_index("idx_jobs_status", "jobs", ["status"])

    # monthly_spend
    op.create_table(
        "monthly_spend",
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("app_users.id"), primary_key=True),
        sa.Column("year_month", sa.CHAR(7), primary_key=True),
        sa.Column("spend_usd", sa.DECIMAL(10, 2), server_default="0"),
        sa.Column("job_count", sa.Integer(), server_default="0"),
        sa.Column("gpu_hours", sa.DECIMAL(10, 2), server_default="0"),
        sa.Column("updated_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
    )

    # audit_log
    op.create_table(
        "audit_log",
        sa.Column("id", sa.BigInteger(), autoincrement=True, primary_key=True),
        sa.Column("user_id", sa.BigInteger(), sa.ForeignKey("app_users.id", ondelete="SET NULL")),
        sa.Column("action", sa.String(64), nullable=False),
        sa.Column("target_type", sa.String(64), nullable=True),
        sa.Column("target_id", sa.String(128), nullable=True),
        sa.Column("details", sa.JSON(), nullable=True),
        sa.Column("ip_address", sa.String(45), nullable=True),
        sa.Column("created_at", sa.DateTime(), server_default=sa.func.current_timestamp()),
    )
    op.create_index("idx_audit_time", "audit_log", ["created_at"])


def downgrade() -> None:
    op.drop_table("audit_log")
    op.drop_table("monthly_spend")
    op.drop_table("jobs")
    op.drop_table("uploads")
    op.drop_table("models")
    op.drop_table("app_users")
