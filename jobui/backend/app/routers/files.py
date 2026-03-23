from fastapi import APIRouter, HTTPException, UploadFile, File, Depends, status
from typing import List, Dict, Any
import urllib.parse

from app.models.schemas import FileInfo, UploadResponse
from app.auth.dependencies import get_current_user
from app.config import get_settings
from app.services import s3_service
from app.utils.logging import get_logger

router = APIRouter(prefix="/files", tags=["files"])
logger = get_logger(__name__)


def _check_s3(settings) -> None:
    if not settings.s3_bucket:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="S3 bucket is not configured",
        )


@router.post("/upload", response_model=UploadResponse)
async def upload_file(
    file: UploadFile = File(...),
    current_user: Dict[str, Any] = Depends(get_current_user),
) -> UploadResponse:
    settings = get_settings()
    _check_s3(settings)

    contents = await file.read()
    if len(contents) == 0:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Uploaded file is empty",
        )

    safe_filename = file.filename.replace("..", "").replace("/", "_").replace("\\", "_")
    key = f"input/{current_user['id']}/{safe_filename}"

    result = s3_service.upload_file(
        file_obj=contents,
        key=key,
        content_type=file.content_type or "application/octet-stream",
        bucket=settings.s3_bucket,
        region=settings.aws_region,
    )

    logger.info(
        "File uploaded",
        extra={"user_id": current_user["id"], "key": key, "size": len(contents)},
    )
    return result


@router.get("", response_model=List[FileInfo])
async def list_files(
    current_user: Dict[str, Any] = Depends(get_current_user),
) -> List[FileInfo]:
    settings = get_settings()
    _check_s3(settings)

    return s3_service.list_user_files(
        user_id=current_user["id"],
        bucket=settings.s3_bucket,
        region=settings.aws_region,
    )


@router.delete("/{key:path}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_file(
    key: str,
    current_user: Dict[str, Any] = Depends(get_current_user),
) -> None:
    settings = get_settings()
    _check_s3(settings)

    # Verify ownership — key must be under input/{user_id}/
    expected_prefix = f"input/{current_user['id']}/"
    if not key.startswith(expected_prefix):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="You do not have permission to delete this file",
        )

    s3_service.delete_prefix(
        prefix=key,
        bucket=settings.s3_bucket,
        region=settings.aws_region,
    )
    logger.info(
        "File deleted",
        extra={"user_id": current_user["id"], "key": key},
    )
