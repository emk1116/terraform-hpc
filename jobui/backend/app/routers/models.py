"""Models catalog — list available, register new (admin)."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import get_current_user, require_admin
from app.cache import cache_get, cache_set
from app.config import get_gpu_spec
from app.database import get_db
from app.models import AppUser, AuditLog, Model as ModelRow
from app.schemas import ModelCreate, ModelOut

router = APIRouter(prefix="/api/models", tags=["models"])

MODELS_CACHE_KEY = "models:all:v1"
MODELS_CACHE_TTL = 60  # 1 min


@router.get("", response_model=list[ModelOut])
def list_models(
    _user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
    gpu_family: Annotated[str | None, Query()] = None,
):
    """List active models. If gpu_family is specified, filter to models that
    allow that GPU and fit in its memory."""

    cached = cache_get(MODELS_CACHE_KEY)
    if cached is None:
        rows = list(
            db.execute(
                select(ModelRow).where(ModelRow.is_active.is_(True)).order_by(
                    ModelRow.display_name
                )
            ).scalars()
        )
        cached = [ModelOut.model_validate(r).model_dump() for r in rows]
        cache_set(MODELS_CACHE_KEY, cached, MODELS_CACHE_TTL)

    if gpu_family:
        spec = get_gpu_spec().get(gpu_family)
        if not spec:
            raise HTTPException(status_code=400, detail=f"Unknown GPU family {gpu_family}")
        gpu_mem = spec["gpu_memory_gb"]
        return [
            ModelOut(**m)
            for m in cached
            if gpu_family in m["allowed_gpus"] and m["gpu_min_memory_gb"] <= gpu_mem
        ]

    return [ModelOut(**m) for m in cached]


@router.post("", response_model=ModelOut, status_code=201)
def register_model(
    req: ModelCreate,
    admin: Annotated[AppUser, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
):
    existing = db.execute(
        select(ModelRow).where(ModelRow.model_key == req.model_key)
    ).scalar_one_or_none()
    if existing:
        raise HTTPException(status_code=409, detail="model_key already exists")

    # Validate allowed_gpus against known families
    known = set(get_gpu_spec().keys())
    bad = set(req.allowed_gpus) - known
    if bad:
        raise HTTPException(
            status_code=400, detail=f"Unknown GPU families: {sorted(bad)}"
        )

    model = ModelRow(
        **req.model_dump(),
        registered_by=admin.id,
    )
    db.add(model)
    db.flush()

    db.add(
        AuditLog(
            user_id=admin.id,
            action="register_model",
            target_type="model",
            target_id=str(model.id),
            details={"model_key": model.model_key, "ecr_uri": model.ecr_uri},
        )
    )
    db.commit()
    db.refresh(model)

    # Invalidate cache
    cache_set(MODELS_CACHE_KEY, None, 1)
    return model


@router.delete("/{model_id}", status_code=204)
def deactivate_model(
    model_id: int,
    admin: Annotated[AppUser, Depends(require_admin)],
    db: Annotated[Session, Depends(get_db)],
):
    model = db.get(ModelRow, model_id)
    if not model:
        raise HTTPException(status_code=404, detail="Model not found")

    model.is_active = False
    db.add(
        AuditLog(
            user_id=admin.id,
            action="deactivate_model",
            target_type="model",
            target_id=str(model.id),
        )
    )
    db.commit()
    cache_set(MODELS_CACHE_KEY, None, 1)
