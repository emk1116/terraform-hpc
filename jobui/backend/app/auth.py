"""Authentication — bcrypt passwords, JWT tokens, FastAPI dependency."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
from typing import Annotated

from fastapi import Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from jose import JWTError, jwt
from passlib.context import CryptContext
from sqlalchemy.orm import Session

from app.config import get_jwt_secret, get_settings
from app.database import get_db
from app.models import AppUser, UserRole

pwd_ctx = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="/api/auth/login")


def hash_password(p: str) -> str:
    return pwd_ctx.hash(p)


def verify_password(plain: str, hashed: str) -> bool:
    return pwd_ctx.verify(plain, hashed)


def create_access_token(user_id: int, username: str, role: UserRole) -> str:
    s = get_settings()
    expire = datetime.now(timezone.utc) + timedelta(hours=s.JWT_EXPIRY_HOURS)
    payload = {
        "sub": str(user_id),
        "username": username,
        "role": role.value,
        "exp": expire,
    }
    return jwt.encode(payload, get_jwt_secret(), algorithm=s.JWT_ALGORITHM)


async def get_current_user(
    token: Annotated[str, Depends(oauth2_scheme)],
    db: Annotated[Session, Depends(get_db)],
) -> AppUser:
    credentials_exc = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Could not validate credentials",
        headers={"WWW-Authenticate": "Bearer"},
    )
    s = get_settings()
    try:
        payload = jwt.decode(token, get_jwt_secret(), algorithms=[s.JWT_ALGORITHM])
        user_id = int(payload.get("sub"))
    except (JWTError, ValueError, TypeError) as e:
        raise credentials_exc from e

    user = db.get(AppUser, user_id)
    if user is None or not user.is_active:
        raise credentials_exc
    return user


async def require_admin(
    user: Annotated[AppUser, Depends(get_current_user)],
) -> AppUser:
    if user.role != UserRole.admin:
        raise HTTPException(status_code=403, detail="Admin only")
    return user
