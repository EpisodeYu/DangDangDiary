"""One-shot backfill: regenerate the small thumbnail tier for legacy photos.

Photos uploaded before the `thumbnail_sm_key` column existed only have the
~400 px tier. The timeline grid will fall back to that tier for them, but
that wastes ~4× the decode memory per cell. This script walks every photo
whose `thumbnail_sm_key` is NULL, downloads the original from MinIO,
generates the small thumbnail, uploads it, and records the new key.

Usage::

    cd backend
    python -m scripts.backfill_thumb_sm                 # run for real
    python -m scripts.backfill_thumb_sm --dry-run       # preview only
    python -m scripts.backfill_thumb_sm --force         # also re-resize
                                                        # rows whose small
                                                        # key already
                                                        # exists (use this
                                                        # after bumping
                                                        # THUMBNAIL_SM_MAX_SIZE)

The script is idempotent: a normal run skips rows that already have a
small key, `--force` re-uploads the small tier from the *current* large
thumbnail so resizing the constant in `storage.THUMBNAIL_SM_MAX_SIZE`
will actually take effect for legacy data. Per-row failures are logged
and skipped without aborting the rest of the batch.
"""
from __future__ import annotations

import argparse
import asyncio
import io
import logging
import sys
from typing import Iterable

from PIL import Image
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine

from app.config import settings
from app.models.photo import Photo
from app.services.storage import (
    THUMBNAIL_QUALITY,
    THUMBNAIL_SM_MAX_SIZE,
    _ensure_bucket,
    _get_client,
)


logger = logging.getLogger("backfill_thumb_sm")


def _build_sm_key_from_thumbnail(thumbnail_key: str) -> str:
    """`<pet>/<uuid>_thumb.jpg` → `<pet>/<uuid>_thumb_sm.jpg`.

    Falls back to appending `_sm` before the extension if the key does not
    follow the standard pattern, so we never overwrite the existing tile.
    """
    if thumbnail_key.endswith("_thumb.jpg"):
        return thumbnail_key[: -len("_thumb.jpg")] + "_thumb_sm.jpg"
    if "." in thumbnail_key:
        stem, ext = thumbnail_key.rsplit(".", 1)
        return f"{stem}_sm.{ext}"
    return f"{thumbnail_key}_sm"


def _resize_to_small(jpeg_bytes: bytes) -> bytes:
    with Image.open(io.BytesIO(jpeg_bytes)) as img:
        if img.mode not in ("RGB", "L"):
            img = img.convert("RGB")
        img.thumbnail(THUMBNAIL_SM_MAX_SIZE, Image.LANCZOS)
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=THUMBNAIL_QUALITY)
        return buf.getvalue()


def _download_object(bucket: str, key: str) -> bytes:
    client = _get_client()
    response = client.get_object(bucket, key)
    try:
        return response.read()
    finally:
        response.close()
        response.release_conn()


def _upload_sm(bucket: str, key: str, data: bytes) -> None:
    client = _get_client()
    client.put_object(
        bucket,
        key,
        io.BytesIO(data),
        length=len(data),
        content_type="image/jpeg",
    )


async def _candidates(session: AsyncSession, *, include_existing: bool) -> Iterable[Photo]:
    stmt = select(Photo).where(Photo.thumbnail_key.is_not(None))
    if not include_existing:
        stmt = stmt.where(Photo.thumbnail_sm_key.is_(None))
    return (await session.execute(stmt)).scalars().all()


async def run(*, dry_run: bool, force: bool) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    _ensure_bucket(settings.MINIO_BUCKET_THUMBNAILS, public=True)

    engine = create_async_engine(settings.DATABASE_URL, echo=False)
    SessionLocal = async_sessionmaker(engine, expire_on_commit=False)

    processed = 0
    failed = 0
    async with SessionLocal() as session:
        rows = list(await _candidates(session, include_existing=force))
        logger.info(
            "Found %d photo(s) to process (force=%s)", len(rows), force,
        )

        for photo in rows:
            sm_key = _build_sm_key_from_thumbnail(photo.thumbnail_key or "")
            if not sm_key:
                logger.warning("Skipping photo id=%s: cannot derive small key", photo.id)
                continue

            if dry_run:
                logger.info(
                    "[dry-run] would create %s/%s for photo id=%s",
                    settings.MINIO_BUCKET_THUMBNAILS, sm_key, photo.id,
                )
                processed += 1
                continue

            try:
                src = _download_object(
                    settings.MINIO_BUCKET_THUMBNAILS, photo.thumbnail_key,
                )
                sm_bytes = _resize_to_small(src)
                _upload_sm(settings.MINIO_BUCKET_THUMBNAILS, sm_key, sm_bytes)
                photo.thumbnail_sm_key = sm_key
                await session.flush()
                processed += 1
                if processed % 25 == 0:
                    await session.commit()
                    logger.info("Committed %d rows so far", processed)
            except Exception as exc:  # noqa: BLE001
                failed += 1
                logger.exception("Failed to backfill photo id=%s: %s", photo.id, exc)

        if not dry_run:
            await session.commit()

    await engine.dispose()
    logger.info(
        "Done. processed=%d failed=%d dry_run=%s force=%s",
        processed, failed, dry_run, force,
    )
    return 1 if failed else 0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print what would be done without writing to MinIO or the DB",
    )
    parser.add_argument(
        "--force",
        action="store_true",
        help=(
            "Re-resize photos that already have a small thumbnail. Use this "
            "after changing THUMBNAIL_SM_MAX_SIZE so legacy small thumbs "
            "are regenerated at the new pixel budget."
        ),
    )
    args = parser.parse_args()
    sys.exit(asyncio.run(run(dry_run=args.dry_run, force=args.force)))


if __name__ == "__main__":
    main()
