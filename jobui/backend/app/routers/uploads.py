"""Uploads router — S3 multipart upload coordination."""

from __future__ import annotations

import uuid
from datetime import datetime
from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from app.auth import get_current_user
from app.database import get_db
from app.models import AppUser, AuditLog, Upload, UploadStatus
from app.s3_uploads import (
    PART_SIZE_BYTES,
    abort_multipart,
    calc_num_parts,
    complete_multipart,
    initiate_multipart,
    presign_part_urls,
)
from app.schemas import (
    UploadCompleteRequest,
    UploadInitRequest,
    UploadInitResponse,
    UploadOut,
    UploadPartUrl,
)

router = APIRouter(prefix="/api/uploads", tags=["uploads"])


@router.post("/init", response_model=UploadInitResponse)
def init_upload(
    req: UploadInitRequest,
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    upload_uuid = str(uuid.uuid4())
    # Per-user prefix in S3
    s3_key = f"input/{user.username}/{upload_uuid}/{req.filename}"

    mp = initiate_multipart(s3_key)
    num_parts = calc_num_parts(req.size_bytes)
    urls = presign_part_urls(s3_key, mp["upload_id"], num_parts)

    upload = Upload(
        id=upload_uuid,
        user_id=user.id,
        filename=req.filename,
        size_bytes=req.size_bytes,
        s3_key=s3_key,
        s3_upload_id=mp["upload_id"],
        status=UploadStatus.initiated,
    )
    db.add(upload)
    db.commit()

    return UploadInitResponse(
        upload_id=upload_uuid,
        s3_upload_id=mp["upload_id"],
        s3_key=s3_key,
        part_size_bytes=PART_SIZE_BYTES,
        part_urls=[UploadPartUrl(**u) for u in urls],
    )


@router.post("/{upload_id}/complete", response_model=UploadOut)
def complete_upload(
    upload_id: str,
    req: UploadCompleteRequest,
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    upload = db.get(Upload, upload_id)
    if not upload or upload.user_id != user.id:
        raise HTTPException(status_code=404, detail="Upload not found")
    if upload.status != UploadStatus.initiated:
        raise HTTPException(status_code=409, detail="Upload not in initiated state")

    # Sort parts by PartNumber (S3 requires ordered list)
    parts = sorted(
        [p.model_dump() for p in req.parts], key=lambda p: p["PartNumber"]
    )

    try:
        etag = complete_multipart(upload.s3_key, upload.s3_upload_id, parts)
    except Exception as e:
        upload.status = UploadStatus.failed
        db.commit()
        raise HTTPException(status_code=500, detail=f"S3 complete failed: {e}") from e

    upload.status = UploadStatus.completed
    upload.completed_at = datetime.utcnow()
    # Store the S3 multipart ETag for integrity tracking (MD5 of part MD5s)
    upload.content_sha256 = etag.strip('"')[:64] if etag else None
    db.add(AuditLog(user_id=user.id, action="upload_complete", target_id=upload.id))
    db.commit()
    db.refresh(upload)
    return upload


@router.post("/{upload_id}/abort", status_code=204)
def abort_upload(
    upload_id: str,
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    upload = db.get(Upload, upload_id)
    if not upload or upload.user_id != user.id:
        raise HTTPException(status_code=404, detail="Upload not found")

    if upload.s3_upload_id and upload.status == UploadStatus.initiated:
        try:
            abort_multipart(upload.s3_key, upload.s3_upload_id)
        except Exception:
            pass  # Best effort; mark aborted regardless

    upload.status = UploadStatus.aborted
    db.commit()


@router.get("", response_model=list[UploadOut])
def list_my_uploads(
    user: Annotated[AppUser, Depends(get_current_user)],
    db: Annotated[Session, Depends(get_db)],
):
    rows = list(
        db.execute(
            select(Upload)
            .where(Upload.user_id == user.id)
            .where(Upload.status == UploadStatus.completed)
            .order_by(Upload.completed_at.desc())
            .limit(50)
        ).scalars()
    )
    return rows
