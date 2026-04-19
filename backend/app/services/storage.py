import asyncio
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

# Decompression-bomb guard (Step 8 §1.2 storage P0). Pillow raises
# `Image.DecompressionBombError` when a single decoded image would exceed
# this pixel budget. 50 MP leaves plenty of headroom for modern phone
# cameras while blocking pathological inputs.
Image.MAX_IMAGE_PIXELS = 50_000_000

_client: Minio | None = None
_initialized_buckets: set[str] = set()

EXT_MAP = {
    "image/jpeg": "jpg",
    "image/png": "png",
    "image/webp": "webp",
}

# Two thumbnail tiers, both stored in the public thumbnails bucket:
#
#   * "lg" (~400 px long side) — used as the placeholder/fallback inside
#     the immersive view and anywhere we render at roughly screen-width.
#   * "sm" (~512 px long side) — served to the 4-column timeline grid.
#
# Naming note: "sm" stands for "small file" (it is the smaller JPEG of the
# two), but its pixel budget is intentionally a bit *larger* than the
# legacy detail tier so the grid stays sharp on modern 1080p phones.
#
# Pixel budget rationale: the grid cell ends up roughly 85 logical px on a
# typical phone, which is 234 physical px at DPR 2.75 (Xiaomi 12T) and 340
# at DPR 4.0. Source images go through BoxFit.cover, so the *short* side
# of the source must be ≥ the cell physical px to avoid paint-time
# upscaling (which is what makes thumbnails look soft). For 4:3 photos
# (the common phone-camera ratio) that means long side ≥ ~340 / 0.75 ≈
# 453 px to cover DPR 4.0; we round up to 512 to also keep 16:9 photos
# crisp on DPR ≤ 3 and only mildly soft on DPR 3.5+. Memory cost is
# unchanged because the client always passes `memCacheWidth ≈ cell-DPR
# px`, so the decoded bitmap is the same regardless of source pixel count.
THUMBNAIL_MAX_SIZE = (400, 400)
THUMBNAIL_SM_MAX_SIZE = (512, 512)
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


def ensure_all_buckets() -> None:
    """Pre-create and configure every bucket used by the app.

    Called once from the FastAPI `lifespan` (Step 8 §1.2 storage P1) so
    request-time paths can skip bucket checks entirely. Safe to invoke
    multiple times — `_ensure_bucket` short-circuits via
    `_initialized_buckets`.
    """
    _ensure_bucket(settings.MINIO_BUCKET_PHOTOS, public=False)
    _ensure_bucket(settings.MINIO_BUCKET_THUMBNAILS, public=True)
    _ensure_bucket(settings.MINIO_BUCKET_AVATARS, public=True)


async def aensure_all_buckets() -> None:
    """Async wrapper around `ensure_all_buckets` for FastAPI lifespan."""
    await asyncio.to_thread(ensure_all_buckets)


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
) -> tuple[str, str, str]:
    """Upload original photo + two thumbnail tiers to MinIO.

    Returns ``(storage_key, thumbnail_key, thumbnail_sm_key)``. The two
    thumbnail keys share the same UUID so they can be cleaned up together.
    """
    photo_bucket = settings.MINIO_BUCKET_PHOTOS
    thumb_bucket = settings.MINIO_BUCKET_THUMBNAILS
    _ensure_bucket(photo_bucket, public=False)
    _ensure_bucket(thumb_bucket, public=True)

    ext = EXT_MAP.get(content_type, "jpg")
    file_uuid = uuid.uuid4().hex
    storage_key = f"{pet_id}/{file_uuid}.{ext}"
    thumbnail_key = f"{pet_id}/{file_uuid}_thumb.jpg"
    thumbnail_sm_key = f"{pet_id}/{file_uuid}_thumb_sm.jpg"

    client = _get_client()

    client.put_object(
        photo_bucket,
        storage_key,
        io.BytesIO(file_data),
        length=len(file_data),
        content_type=content_type,
    )

    # Decode the source once and downsample to both tiers, so the second
    # tier costs nothing beyond a re-resize and JPEG encode.
    thumb_data, thumb_sm_data = _generate_thumbnails(file_data)
    client.put_object(
        thumb_bucket,
        thumbnail_key,
        io.BytesIO(thumb_data),
        length=len(thumb_data),
        content_type="image/jpeg",
    )
    client.put_object(
        thumb_bucket,
        thumbnail_sm_key,
        io.BytesIO(thumb_sm_data),
        length=len(thumb_sm_data),
        content_type="image/jpeg",
    )

    return storage_key, thumbnail_key, thumbnail_sm_key


def _generate_thumbnails(file_data: bytes) -> tuple[bytes, bytes]:
    """Decode source once, return (large_jpeg, small_jpeg) bytes.

    `Image.MAX_IMAGE_PIXELS` and the `with` block guard against
    decompression-bomb inputs and leaked file handles (Step 8 §1.2
    storage P0).

    Both tiers downsample from the *original* decoded image rather than
    chaining (large → small). This matters now that the small tier
    (512 px) is allowed to be larger than the large tier (400 px); if we
    derived `small` from `large` it would be capped at 400 px and the
    grid would silently lose half the resolution we asked for.
    """
    with Image.open(io.BytesIO(file_data)) as img:
        if img.mode not in ("RGB", "L"):
            img = img.convert("RGB")

        large = img.copy()
        large.thumbnail(THUMBNAIL_MAX_SIZE, Image.LANCZOS)

        small = img.copy()
        small.thumbnail(THUMBNAIL_SM_MAX_SIZE, Image.LANCZOS)

        large_buf = io.BytesIO()
        small_buf = io.BytesIO()
        large.save(large_buf, format="JPEG", quality=THUMBNAIL_QUALITY)
        small.save(small_buf, format="JPEG", quality=THUMBNAIL_QUALITY)
        return large_buf.getvalue(), small_buf.getvalue()


# Kept for backwards compat with any external caller; new code should
# use `_generate_thumbnails`.
def _generate_thumbnail(file_data: bytes) -> bytes:
    large, _small = _generate_thumbnails(file_data)
    return large


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


def delete_photo_objects(
    storage_key: str,
    thumbnail_key: str | None,
    thumbnail_sm_key: str | None = None,
) -> None:
    client = _get_client()
    try:
        client.remove_object(settings.MINIO_BUCKET_PHOTOS, storage_key)
    except Exception:
        logger.warning("Failed to delete original photo: %s", storage_key)
    for key in (thumbnail_key, thumbnail_sm_key):
        if not key:
            continue
        try:
            client.remove_object(settings.MINIO_BUCKET_THUMBNAILS, key)
        except Exception:
            logger.warning("Failed to delete thumbnail: %s", key)


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


# =======================================================================
# Async wrappers (Step 8 §1.1 rule 4 / Chunk B-5)
#
# MinIO SDK is synchronous. Any sync MinIO or Pillow call invoked from a
# FastAPI route must be dispatched to a worker thread so it does not
# block the asyncio event loop. `asyncio.to_thread` is preferred over
# building a dedicated executor because the call volume is low and the
# default thread pool is already sized for this workload.
# =======================================================================


async def aupload_photo(
    pet_id: int, file_data: bytes, content_type: str,
) -> tuple[str, str, str]:
    return await asyncio.to_thread(upload_photo, pet_id, file_data, content_type)


async def aupload_pet_avatar(
    pet_id: int, data: bytes, content_type: str,
) -> str:
    return await asyncio.to_thread(upload_pet_avatar, pet_id, data, content_type)


async def adelete_photo_objects(
    storage_key: str,
    thumbnail_key: str | None,
    thumbnail_sm_key: str | None = None,
) -> None:
    await asyncio.to_thread(
        delete_photo_objects, storage_key, thumbnail_key, thumbnail_sm_key,
    )


async def adelete_object_by_url(url: str) -> None:
    await asyncio.to_thread(delete_object_by_url, url)


async def adelete_objects_by_prefix(bucket: str, prefix: str) -> None:
    await asyncio.to_thread(delete_objects_by_prefix, bucket, prefix)
