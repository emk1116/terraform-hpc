import boto3
from botocore.exceptions import ClientError, NoCredentialsError, BotoCoreError
from fastapi import HTTPException, status
from typing import List, Dict, Any
from datetime import datetime, timezone

from app.models.schemas import FileInfo, UploadResponse
from app.utils.logging import get_logger

logger = get_logger(__name__)


def _get_client(region: str):
    return boto3.client("s3", region_name=region)


def upload_file(
    file_obj: bytes,
    key: str,
    content_type: str,
    bucket: str,
    region: str,
) -> UploadResponse:
    client = _get_client(region)
    try:
        client.put_object(
            Bucket=bucket,
            Key=key,
            Body=file_obj,
            ContentType=content_type,
        )
        filename = key.split("/")[-1]
        return UploadResponse(
            key=key,
            filename=filename,
            size=len(file_obj),
            message=f"File uploaded successfully to s3://{bucket}/{key}",
        )
    except NoCredentialsError:
        logger.error("AWS credentials not found")
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="AWS credentials not configured",
        )
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        logger.error("S3 upload failed", extra={"error_code": error_code, "key": key})
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"S3 upload failed: {error_code}",
        )
    except BotoCoreError as e:
        logger.error("S3 upload boto error", extra={"error": str(e)})
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"S3 error: {e}",
        )


def list_user_files(user_id: str, bucket: str, region: str) -> List[FileInfo]:
    client = _get_client(region)
    prefix = f"input/{user_id}/"
    files: List[FileInfo] = []

    try:
        paginator = client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                if key == prefix:
                    continue
                filename = key[len(prefix):]
                if not filename:
                    continue
                last_modified = obj["LastModified"]
                if hasattr(last_modified, "isoformat"):
                    last_modified_str = last_modified.isoformat()
                else:
                    last_modified_str = str(last_modified)
                files.append(
                    FileInfo(
                        key=key,
                        size=obj["Size"],
                        last_modified=last_modified_str,
                        filename=filename,
                    )
                )
        return files
    except NoCredentialsError:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="AWS credentials not configured",
        )
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"S3 list failed: {error_code}",
        )


def list_results(job_id: str, bucket: str, region: str) -> List[Dict[str, Any]]:
    client = _get_client(region)
    prefix = f"results/{job_id}/"
    results: List[Dict[str, Any]] = []

    try:
        paginator = client.get_paginator("list_objects_v2")
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                key = obj["Key"]
                if key == prefix:
                    continue
                filename = key[len(prefix):]
                if not filename:
                    continue
                last_modified = obj["LastModified"]
                if hasattr(last_modified, "isoformat"):
                    last_modified_str = last_modified.isoformat()
                else:
                    last_modified_str = str(last_modified)
                results.append(
                    {
                        "key": key,
                        "filename": filename,
                        "size": obj["Size"],
                        "last_modified": last_modified_str,
                    }
                )
        return results
    except NoCredentialsError:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="AWS credentials not configured",
        )
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"S3 list results failed: {error_code}",
        )


def generate_presigned_url(key: str, bucket: str, region: str, expiry: int) -> str:
    client = _get_client(region)
    try:
        url = client.generate_presigned_url(
            "get_object",
            Params={"Bucket": bucket, "Key": key},
            ExpiresIn=expiry,
        )
        return url
    except (ClientError, BotoCoreError) as e:
        logger.error("Failed to generate presigned URL", extra={"key": key, "error": str(e)})
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Failed to generate download URL: {e}",
        )


def delete_prefix(prefix: str, bucket: str, region: str) -> None:
    client = _get_client(region)
    try:
        paginator = client.get_paginator("list_objects_v2")
        objects_to_delete = []
        for page in paginator.paginate(Bucket=bucket, Prefix=prefix):
            for obj in page.get("Contents", []):
                objects_to_delete.append({"Key": obj["Key"]})

        if objects_to_delete:
            # Delete in batches of 1000 (S3 limit)
            for i in range(0, len(objects_to_delete), 1000):
                batch = objects_to_delete[i : i + 1000]
                client.delete_objects(
                    Bucket=bucket,
                    Delete={"Objects": batch, "Quiet": True},
                )
    except NoCredentialsError:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="AWS credentials not configured",
        )
    except ClientError as e:
        error_code = e.response["Error"]["Code"]
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"S3 delete failed: {error_code}",
        )
