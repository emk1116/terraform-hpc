from fastapi import APIRouter, HTTPException, status, Depends
from typing import Dict, Any

from app.models.schemas import Token, LoginRequest, UserResponse
from app.auth.jwt_handler import create_access_token
from app.auth.dependencies import get_current_user
from app.config import get_settings
from app.database import get_user_by_username, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/login", response_model=Token)
async def login(request: LoginRequest) -> Token:
    settings = get_settings()
    user = get_user_by_username(settings.db_path, request.username)

    if user is None or not verify_password(request.password, user["hashed_password"]):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Incorrect username or password",
            headers={"WWW-Authenticate": "Bearer"},
        )

    token_data = {
        "sub": user["id"],
        "username": user["username"],
        "cluster_user": user["cluster_user"],
        "is_admin": bool(user["is_admin"]),
    }
    access_token = create_access_token(token_data)
    return Token(access_token=access_token)


@router.get("/me", response_model=UserResponse)
async def get_me(current_user: Dict[str, Any] = Depends(get_current_user)) -> UserResponse:
    return UserResponse(
        id=current_user["id"],
        username=current_user["username"],
        cluster_user=current_user["cluster_user"],
        is_admin=bool(current_user["is_admin"]),
    )
