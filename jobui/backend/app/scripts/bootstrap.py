"""First-boot bootstrap: seed admin user + team members from the SSM seed.

Runs before uvicorn in the Docker CMD. Idempotent — safe to rerun.
"""

from __future__ import annotations

import logging
import sys
from decimal import Decimal

from sqlalchemy import select

from app.auth import hash_password
from app.config import get_admin_temp_password, get_users_seed
from app.database import SessionLocal, engine
from app.models import AppUser, UserRole

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("bootstrap")


def bootstrap():
    # Check DB is reachable
    try:
        with engine.connect() as c:
            c.exec_driver_sql("SELECT 1")
    except Exception as e:
        log.error("Cannot reach Aurora: %s", e)
        sys.exit(1)

    seed = get_users_seed()
    admin_email = seed["admin"]["email"]
    admin_temp = get_admin_temp_password()

    with SessionLocal() as db:
        # --- Admin user ---
        admin_username = admin_email.split("@")[0]
        existing_admin = db.execute(
            select(AppUser).where(AppUser.email == admin_email)
        ).scalar_one_or_none()

        if existing_admin is None:
            log.info("creating admin user %s", admin_username)
            admin = AppUser(
                username=admin_username,
                email=admin_email,
                display_name="Admin",
                password_hash=hash_password(admin_temp),
                role=UserRole.admin,
                slurm_account="h100-approved",
                h100_approved=True,
                monthly_budget_usd=Decimal("10000"),
                must_change_password=True,
                is_active=True,
            )
            db.add(admin)
        else:
            log.info("admin %s already exists; skipping", admin_username)

        # --- Team members ---
        for m in seed.get("members", []):
            existing = db.execute(
                select(AppUser).where(AppUser.username == m["username"])
            ).scalar_one_or_none()
            if existing is not None:
                continue

            log.info("creating member %s", m["username"])
            slurm_acct = "h100-approved" if m["h100_approved"] else "general"
            member = AppUser(
                username=m["username"],
                email=m["email"],
                display_name=m.get("display_name"),
                # Temp password = admin_temp for all seeded members; they must change on first login
                password_hash=hash_password(admin_temp),
                role=UserRole(m["role"]),
                slurm_account=slurm_acct,
                h100_approved=m["h100_approved"],
                monthly_budget_usd=Decimal(str(m["monthly_budget_usd"])),
                must_change_password=True,
                is_active=True,
            )
            db.add(member)

        db.commit()

    log.info("bootstrap complete")


if __name__ == "__main__":
    bootstrap()
