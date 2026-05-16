"""Cost estimation and budget enforcement.

Cost is estimated at submit-time from:
  hourly_cost_usd (from gpu_family_spec) × requested_hours
This becomes jobs.estimated_cost_usd and is checked against the user's
remaining monthly budget before we shell out to sbatch.

Actual cost is computed later (after the job ends) from Slurm sacct's
TRES seconds and written to jobs.actual_cost_usd by the rollup cron.
"""

from __future__ import annotations

from datetime import date
from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.config import get_gpu_spec
from app.models import AppUser, MonthlySpend


def estimate_cost_usd(gpu_family: str, hours: int) -> Decimal:
    spec = get_gpu_spec().get(gpu_family)
    if spec is None:
        raise ValueError(f"unknown GPU family: {gpu_family}")
    hourly = Decimal(str(spec["hourly_cost_usd"]))
    return (hourly * Decimal(hours)).quantize(Decimal("0.0001"))


def current_month_str() -> str:
    t = date.today()
    return f"{t.year:04d}-{t.month:02d}"


def get_remaining_budget(db: Session, user: AppUser) -> Decimal:
    """Returns how much USD the user has left this month."""
    month = current_month_str()
    stmt = select(MonthlySpend).where(
        MonthlySpend.user_id == user.id,
        MonthlySpend.year_month == month,
    )
    row = db.execute(stmt).scalar_one_or_none()
    spent = row.spend_usd if row else Decimal("0")
    return user.monthly_budget_usd - spent


def check_budget_or_raise(db: Session, user: AppUser, estimated: Decimal):
    remaining = get_remaining_budget(db, user)
    if estimated > remaining:
        from fastapi import HTTPException
        raise HTTPException(
            status_code=402,
            detail=(
                f"Estimated job cost ${estimated:.2f} exceeds remaining "
                f"monthly budget ${remaining:.2f}. "
                "Contact your team admin to increase your budget."
            ),
        )
