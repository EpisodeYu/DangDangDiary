import io
import json
import logging
import time
import uuid
from datetime import timedelta
from urllib.parse import urlparse

from minio import Minio
from PIL import Image

from app.config import settings

logger = logging.getLogger(__name__)

_client: Minio | None = None
_initialized_buckets: set[str] = set()

EXT_MAP = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
}

THUMBNAIL_MAX_SIZE = (400, 400)
THUMBNAIL_QUALITY = 80


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


def _ensure_bucket(bucket: str, *, public: bool = True) -> None:
    if bucket in _initialized_buckets:
        return
    client = _get_client()
    if not client.bucket_exists(bucket):
        client.make_bucket(bucket)
    if public:
        client.set_bucket_policy(bucket, _public_read_policy(bucket))
    _initialized_buckets.add(bucket)


def upload_pet_avatar(pet_id: int, data: bytes, content_type: str) -> str:
    """Upload pet avatar and return the public URL path."""
    bucket = settings.MINIO_BUCKET_AVATARS
    _ensure_bucket(bucket)

    ext = EXT_MAP.get(content_type, "jpg")
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


def upload_photo(
    pet_id: int, file_data: bytes, content_type: str
) -> tuple[str, str]:
    """Upload original photo and generated thumbnail to MinIO.

    Returns (storage_key, thumbnail_key).
    """
    photo_bucket = settings.MINIO_BUCKET_PHOTOS
    thumb_bucket = settings.MINIO_BUCKET_THUMBNAILS
    _ensure_bucket(photo_bucket, public=False)
    _ensure_bucket(thumb_bucket, public=True)

    ext = EXT_MAP.get(content_type, "jpg")
    file_uuid = uuid.uuid4().hex
    storage_key = f"{pet_id}/{file_uuid}.{ext}"
    thumbnail_key = f"{pet_id}/{file_uuid}_thumb.jpg"

    client = _get_client()

    client.put_object(
        photo_bucket,
        storage_key,
        io.BytesIO(file_data),
        length=len(file_data),
        content_type=content_type,
    )

    thumb_data = _generate_thumbnail(file_data)
    client.put_object(
        thumb_bucket,
        thumbnail_key,
        io.BytesIO(thumb_data),
        length=len(thumb_data),
        content_type="image/jpeg",
    )

    return storage_key, thumbnail_key


def _generate_thumbnail(file_data: bytes) -> bytes:
    img = Image.open(io.BytesIO(file_data))
    img.thumbnail(THUMBNAIL_MAX_SIZE, Image.LANCZOS)
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=THUMBNAIL_QUALITY)
    return buf.getvalue()


def build_thumbnail_url(thumbnail_key: str) -> str:
    return f"{settings.PUBLIC_BASE_URL}/media/{settings.MINIO_BUCKET_THUMBNAILS}/{thumbnail_key}"


def get_photo_presigned_url(storage_key: str, expires_seconds: int = 3600) -> str:
    """Generate a presigned URL for the original photo, rewritten to public entry."""
    photo_bucket = settings.MINIO_BUCKET_PHOTOS
    _ensure_bucket(photo_bucket, public=False)
    client = _get_client()
    internal_url = client.presigned_get_object(
        photo_bucket,
        storage_key,
        expires=timedelta(seconds=expires_seconds),
    )
    parsed = urlparse(internal_url)
    return f"{settings.PUBLIC_BASE_URL}/media/{photo_bucket}/{storage_key}?{parsed.query}"


def delete_photo_objects(storage_key: str, thumbnail_key: str | None) -> None:
    client = _get_client()
    try:
        client.remove_object(settings.MINIO_BUCKET_PHOTOS, storage_key)
    except Exception:
        logger.warning("Failed to delete original photo: %s", storage_key)
    if thumbnail_key:
        try:
            client.remove_object(settings.MINIO_BUCKET_THUMBNAILS, thumbnail_key)
        except Exception:
            logger.warning("Failed to delete thumbnail: %s", thumbnail_key)


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
    _ensure_bucket(bucket, public=False)
    objects = client.list_objects(bucket, prefix=prefix, recursive=True)
    for obj in objects:
        try:
            client.remove_object(bucket, obj.object_name)
        except Exception:
            pass
