"""Auth router — login, password change, me."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import (
    create_access_token,
    get_current_user,
    hash_password,
    verify_password,
)
from app.database import get_db
from app.models import AppUser, AuditLog
from app.schemas import (
    ChangePasswordRequest,
    LoginRequest,
    TokenResponse,
    UserOut,
)

router = APIRouter(prefix="/api/auth", tags=["auth"])


@router.post("/login", response_model=TokenResponse)
def login(
    req: LoginRequest,
    db: Annotated[Session, Depends(get_db)],
):
    user = db.execute(
        select(AppUser).where(AppUser.username == req.username)
    ).scalar_one_or_none()

    if user is None or not verify_password(req.password, user.password_hash):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    if not user.is_active:
        raise HTTPException(status_code=403, detail="Account inactive")

    token = create_access_token(user.id, user.username, user.role)

    db.add(AuditLog(user_id=user.id, action="login"))
    db.commit()

    return TokenResponse(
        access_token=token,
        must_change_password=user.must_change_password,
    )


@router.post("/change-password", status_code=status.HTTP_204_NO_CONTENT)
def change_password(
    req: ChangePasswordRequest,
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    if not verify_password(req.current_password, user.password_hash):
        raise HTTPException(status_code=401, detail="Current password incorrect")

    user.password_hash = hash_password(req.new_password)
    user.must_change_password = False
    db.add(AuditLog(user_id=user.id, action="change_password"))
    db.commit()


@router.get("/me", response_model=UserOut)
def me(user: Annotated[AppUser, Depends(get_current_user)]):
    return user
