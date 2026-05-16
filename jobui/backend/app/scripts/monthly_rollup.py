"""Hourly rollup: reads Slurm sacct data via the reader DB connection,
computes GPU-hours per user for the current month, updates monthly_spend.

Runs from /etc/cron.hourly/titan-spend-rollup on the head node.
"""

from __future__ import annotations

import logging
from datetime import date, datetime, timezone
from decimal import Decimal

from sqlalchemy import select, text
from sqlalchemy.dialects.mysql import insert as mysql_insert

from app.config import get_gpu_spec
from app.database import ReaderSessionLocal, SessionLocal
from app.models import AppUser, Job, JobStatus, MonthlySpend

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("rollup")


def rollup():
    month = f"{date.today().year:04d}-{date.today().month:02d}"
    month_start = datetime(date.today().year, date.today().month, 1, tzinfo=timezone.utc)

    spec = get_gpu_spec()

    with SessionLocal() as db:
        # For each user, sum estimated cost of completed-or-running jobs this month.
        # We use estimated_cost for budget enforcement. Actual cost is adjusted
        # from sacct once a job ends.
        users = list(db.execute(select(AppUser)).scalars())

        for user in users:
            completed_jobs = list(
                db.execute(
                    select(Job).where(
                        Job.user_id == user.id,
                        Job.submitted_at >= month_start,
                        Job.status.in_(
                            [
                                JobStatus.completed,
                                JobStatus.running,
                                JobStatus.pending,
                                JobStatus.submitted,
                            ]
                        ),
                    )
                ).scalars()
            )

            total_spend = Decimal("0")
            total_hours = Decimal("0")
            job_count = 0

            for j in completed_jobs:
                # Use actual if available, estimated otherwise
                cost = j.actual_cost_usd if j.actual_cost_usd else j.estimated_cost_usd
                total_spend += cost
                total_hours += Decimal(j.requested_hours)
                job_count += 1

            # Upsert
            stmt = mysql_insert(MonthlySpend).values(
                user_id=user.id,
                year_month=month,
                spend_usd=total_spend,
                job_count=job_count,
                gpu_hours=total_hours,
            )
            stmt = stmt.on_duplicate_key_update(
                spend_usd=total_spend,
                job_count=job_count,
                gpu_hours=total_hours,
            )
            db.execute(stmt)

        db.commit()

    log.info("rollup complete for %s", month)


def sync_slurm_actuals():
    """For jobs in RUNNING state, check Slurm and update status/actual_cost.
    This function can be called more frequently than the spend rollup.
    """
    with SessionLocal() as db, ReaderSessionLocal() as slurm_db:
        active = list(
            db.execute(
                select(Job).where(
                    Job.status.in_(
                        [JobStatus.submitted, JobStatus.pending, JobStatus.running]
                    ),
                    Job.slurm_job_id.is_not(None),
                )
            ).scalars()
        )

        if not active:
            return

        slurm_ids = [j.slurm_job_id for j in active]
        # Query slurm_acct_db directly
        cluster_name = "titan-" + active[0].slurm_account.split("-")[0]  # best effort
        # Simpler: query the job_table ourselves
        sql = text(
            f"""
            SELECT id_job, state, time_start, time_end, tres_alloc
            FROM `{cluster_name}_job_table`
            WHERE id_job IN :ids
            """
        )
        try:
            rows = slurm_db.execute(sql, {"ids": tuple(slurm_ids)}).fetchall()
        except Exception as e:
            log.warning("slurm query failed (is cluster name correct?): %s", e)
            return

        # Slurm state codes: 0=PENDING, 1=RUNNING, 3=COMPLETED, 5=FAILED, 6=TIMEOUT, etc.
        state_map = {
            0: JobStatus.pending,
            1: JobStatus.running,
            3: JobStatus.completed,
            4: JobStatus.cancelled,
            5: JobStatus.failed,
            6: JobStatus.failed,
        }

        by_id = {r.id_job: r for r in rows}
        for j in active:
            r = by_id.get(j.slurm_job_id)
            if r is None:
                continue
            j.status = state_map.get(r.state, j.status)
            if r.time_start:
                j.started_at = datetime.fromtimestamp(r.time_start)
            if r.time_end:
                j.ended_at = datetime.fromtimestamp(r.time_end)

        db.commit()


if __name__ == "__main__":
    sync_slurm_actuals()
    rollup()
