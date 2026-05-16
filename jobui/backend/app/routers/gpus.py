"""GPUs router — available GPU families + cost preview."""

from __future__ import annotations

from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.auth import get_current_user
from app.config import get_gpu_spec
from app.costing import (
    current_month_str,
    estimate_cost_usd,
    get_remaining_budget,
)
from app.database import get_db
from app.models import AppUser
from app.schemas import CostPreviewRequest, CostPreviewResponse, GpuOption

router = APIRouter(prefix="/api/gpus", tags=["gpus"])


GPU_DISPLAY_NAMES = {
    "t4":       "T4 — 16 GB",
    "a10g":     "A10G — 24 GB",
    "l4":       "L4 — 24 GB",
    "a100":     "A100 — 40 GB (8×)",
    "h100-1x":  "H100 — 80 GB (single)",
    "h100-8x":  "H100 — 80 GB (8× NVLink)",
}


@router.get("", response_model=list[GpuOption])
def list_gpus(user: Annotated[AppUser, Depends(get_current_user)]):
    """Return GPUs this user can see in the dropdown.

    Users who are not h100_approved will not see H100 partitions at all —
    cleaner UX than showing a grayed-out option that errors on submit.
    """
    spec = get_gpu_spec()
    out = []
    for family, s in spec.items():
        requires_h100 = family.startswith("h100")
        if requires_h100 and not user.h100_approved:
            continue
        out.append(
            GpuOption(
                family=family,
                display_name=GPU_DISPLAY_NAMES.get(family, family),
                partition=s["partition"],
                instance_type=s["instance_type"],
                gpu_memory_gb=s["gpu_memory_gb"],
                gpus_per_node=s["gpus_per_node"],
                hourly_cost_usd=s["hourly_cost_usd"],
                requires_approval=requires_h100,
            )
        )
    return out


@router.post("/cost-preview", response_model=CostPreviewResponse)
def cost_preview(
    req: CostPreviewRequest,
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    spec = get_gpu_spec().get(req.gpu_family)
    if not spec:
        from fastapi import HTTPException
        raise HTTPException(status_code=400, detail="Unknown GPU family")

    estimated = estimate_cost_usd(req.gpu_family, req.hours)
    remaining = get_remaining_budget(db, user)

    return CostPreviewResponse(
        gpu_family=req.gpu_family,
        hours=req.hours,
        hourly_rate_usd=spec["hourly_cost_usd"],
        estimated_cost_usd=estimated,
        remaining_budget_usd=remaining,
        will_exceed_budget=estimated > remaining,
    )
