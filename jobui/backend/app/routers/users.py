"""Users router — admin manages team members."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import get_current_user, hash_password, require_admin
from app.database import get_db
from app.models import AppUser, AuditLog, UserRole
from app.schemas import UserCreate, UserOut, UserUpdate

router = APIRouter(prefix="/api/users", tags=["users"])


@router.get("", response_model=list[UserOut])
def list_users(
    _admin: Annotated[AppUser, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
):
    return list(db.execute(select(AppUser).order_by(AppUser.username)).scalars())


@router.post("", response_model=UserOut, status_code=201)
def create_user(
    req: UserCreate,
    admin: Annotated[AppUser, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
):
    existing = db.execute(
        select(AppUser).where(
            (AppUser.username == req.username) | (AppUser.email == req.email)
        )
    ).scalar_one_or_none()
    if existing:
        raise HTTPException(status_code=409, detail="Username or email already exists")

    slurm_account = "h100-approved" if req.h100_approved else "general"

    user = AppUser(
        username=req.username,
        email=req.email,
        display_name=req.display_name,
        password_hash=hash_password(req.temp_password),
        role=UserRole(req.role),
        slurm_account=slurm_account,
        h100_approved=req.h100_approved,
        monthly_budget_usd=req.monthly_budget_usd,
        must_change_password=True,
        is_active=True,
    )
    db.add(user)
    db.flush()

    db.add(
        AuditLog(
            user_id=admin.id,
            action="create_user",
            target_type="user",
            target_id=str(user.id),
            details={"username": user.username, "h100_approved": user.h100_approved},
        )
    )
    db.commit()
    db.refresh(user)
    return user


@router.patch("/{user_id}", response_model=UserOut)
def update_user(
    user_id: int,
    req: UserUpdate,
    admin: Annotated[AppUser, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
):
    user = db.get(AppUser, user_id)
    if not user:
        raise HTTPException(status_code=404, detail="User not found")

    changes = req.model_dump(exclude_unset=True)
    for field, value in changes.items():
        if field == "role" and value is not None:
            setattr(user, field, UserRole(value))
        else:
            setattr(user, field, value)

    # Sync slurm_account if h100_approved changed
    if "h100_approved" in changes:
        user.slurm_account = "h100-approved" if user.h100_approved else "general"

    db.add(
        AuditLog(
            user_id=admin.id,
            action="update_user",
            target_type="user",
            target_id=str(user.id),
            details=changes,
        )
    )
    db.commit()
    db.refresh(user)
    return user
