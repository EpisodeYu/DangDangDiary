import io
import json
import time
from urllib.parse import urlparse

from minio import Minio

from app.config import settings

_client: Minio | None = None
_initialized_buckets: set[str] = set()


def _get_client() -> Minio:
    global _client
    if _client is None:
        _client = Minio(
            settings.MINIO_ENDPOINT,
            access_key=settings.MINIO_ACCESS_KEY,
            secret_key=settings.MINIO_SECRET_KEY,
            secure=settings.MINIO_SECURE,
        )
    return _client


def _public_read_policy(bucket: str) -> str:
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [
            {
                "Effect": "Allow",
                "Principal": {"AWS": ["*"]},
                "Action": ["s3:GetObject"],
                "Resource": [f"arn:aws:s3:::{bucket}/*"],
            }
        ],
    })


def _ensure_bucket(bucket: str) -> None:
    if bucket in _initialized_buckets:
        return
    client = _get_client()
    if not client.bucket_exists(bucket):
        client.make_bucket(bucket)
    client.set_bucket_policy(bucket, _public_read_policy(bucket))
    _initialized_buckets.add(bucket)


def upload_pet_avatar(pet_id: int, data: bytes, content_type: str) -> str:
    """Upload pet avatar and return the public URL path."""
    bucket = settings.MINIO_BUCKET_AVATARS
    _ensure_bucket(bucket)

    ext_map = {
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/webp": "webp",
    }
    ext = ext_map.get(content_type, "jpg")
    object_key = f"pets/{pet_id}/{int(time.time())}.{ext}"

    client = _get_client()
    client.put_object(
        bucket,
        object_key,
        io.BytesIO(data),
        length=len(data),
        content_type=content_type,
    )

    return f"{settings.PUBLIC_BASE_URL}/media/{bucket}/{object_key}"


def delete_object_by_url(url: str) -> None:
    """Delete an object from MinIO given its public URL."""
    if not url:
        return

    parsed = urlparse(url)
    path = parsed.path
    if path.startswith("/media/"):
        path = path[len("/media/"):]

    parts = path.split("/", 1)
    if len(parts) != 2:
        return

    bucket, object_key = parts
    client = _get_client()
    try:
        client.remove_object(bucket, object_key)
    except Exception:
        pass


def delete_objects_by_prefix(bucket: str, prefix: str) -> None:
    """Delete all objects under a prefix in a bucket."""
    client = _get_client()
    _ensure_bucket(bucket)
    objects = client.list_objects(bucket, prefix=prefix, recursive=True)
    for obj in objects:
        try:
            client.remove_object(bucket, obj.object_name)
        except Exception:
            pass
