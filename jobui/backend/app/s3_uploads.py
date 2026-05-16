"""S3 multipart upload helpers.

Flow:
1. Client calls initiate_multipart → we create the multipart upload, return
   UploadId + per-part presigned PUT URLs
2. Client uploads each part directly to S3 using those URLs
3. Client calls complete_multipart with the ETags → we CompleteMultipartUpload
4. Server marks Upload row as completed

A 5 GB file with 8 MB parts = 640 parts, uploaded in parallel (~10 at a time)
completes in ~1-2 minutes on a good connection.
"""

from __future__ import annotations

from functools import lru_cache

import boto3
from botocore.config import Config

from app.config import get_settings

PART_SIZE_BYTES = 8 * 1024 * 1024
PRESIGN_TTL_SECONDS = 3600


@lru_cache
def _s3():
    s = get_settings()
    return boto3.client(
        "s3",
        region_name=s.AWS_REGION,
        config=Config(signature_version="s3v4", s3={"addressing_style": "virtual"}),
    )


def initiate_multipart(key: str, content_type: str = "application/octet-stream") -> dict:
    """Creates a multipart upload and returns UploadId."""
    s = get_settings()
    resp = _s3().create_multipart_upload(
        Bucket=s.S3_BUCKET,
        Key=key,
        ContentType=content_type,
        ServerSideEncryption="AES256",
    )
    return {"upload_id": resp["UploadId"], "key": key, "bucket": s.S3_BUCKET}


def presign_part_urls(key: str, upload_id: str, num_parts: int) -> list[dict]:
    s = get_settings()
    urls = []
    for part_number in range(1, num_parts + 1):
        url = _s3().generate_presigned_url(
            ClientMethod="upload_part",
            Params={
                "Bucket": s.S3_BUCKET,
                "Key": key,
                "UploadId": upload_id,
                "PartNumber": part_number,
            },
            ExpiresIn=PRESIGN_TTL_SECONDS,
            HttpMethod="PUT",
        )
        urls.append({"part_number": part_number, "url": url})
    return urls


def complete_multipart(key: str, upload_id: str, parts: list[dict]) -> str:
    """
    parts: [{"PartNumber": 1, "ETag": "xxx"}, ...]
    Returns the final object's ETag.
    """
    s = get_settings()
    resp = _s3().complete_multipart_upload(
        Bucket=s.S3_BUCKET,
        Key=key,
        UploadId=upload_id,
        MultipartUpload={"Parts": parts},
    )
    return resp.get("ETag", "")


def abort_multipart(key: str, upload_id: str):
    s = get_settings()
    _s3().abort_multipart_upload(Bucket=s.S3_BUCKET, Key=key, UploadId=upload_id)


def presign_get_url(key: str, ttl_seconds: int = 3600) -> str:
    s = get_settings()
    return _s3().generate_presigned_url(
        ClientMethod="get_object",
        Params={"Bucket": s.S3_BUCKET, "Key": key},
        ExpiresIn=ttl_seconds,
    )


def list_prefix(prefix: str) -> list[dict]:
    s = get_settings()
    resp = _s3().list_objects_v2(Bucket=s.S3_BUCKET, Prefix=prefix)
    return [
        {"key": o["Key"], "size": o["Size"], "last_modified": o["LastModified"]}
        for o in resp.get("Contents", [])
    ]


def calc_num_parts(size_bytes: int) -> int:
    parts = size_bytes // PART_SIZE_BYTES
    if size_bytes % PART_SIZE_BYTES:
        parts += 1
    return max(1, parts)
