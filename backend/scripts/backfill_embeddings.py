"""One-shot backfill: compute DashScope embeddings for every existing photo
and write them into ``pet_photo_embeddings`` so the classify endpoint has
a non-empty pool from day one.

Only needed once, right after the Phase 2 Step 3 migration lands on an
instance that already had uploaded photos under the old flow. Safe to run
multiple times — it skips photos that already have at least one embedding.

Usage:

    cd backend
    source .venv/bin/activate
    python -m scripts.backfill_embeddings
"""
from __future__ import annotations

import asyncio
import logging
import sys

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import async_session_maker
from app.models.pet_photo_embedding import EmbeddingSource, PetPhotoEmbedding
from app.models.photo import Photo
from app.services.embedding import EmbeddingUnavailableError, embed_image
from app.services.pet_centroid import add_embedding
from app.services.storage import _get_client
from app.config import settings


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("backfill")


async def _photo_bytes(storage_key: str) -> bytes | None:
    """Pull the original photo blob from MinIO."""
    client = _get_client()
    try:
        resp = await asyncio.to_thread(
            client.get_object, settings.MINIO_BUCKET_PHOTOS, storage_key,
        )
    except Exception as e:
        logger.warning("minio get_object failed key=%s err=%s", storage_key, e)
        return None
    try:
        data = await asyncio.to_thread(resp.read)
        return data
    finally:
        await asyncio.to_thread(resp.close)
        await asyncio.to_thread(resp.release_conn)


async def _photo_has_embedding(session: AsyncSession, photo_id: int) -> bool:
    stmt = select(PetPhotoEmbedding.id).where(
        PetPhotoEmbedding.photo_id == photo_id,
    ).limit(1)
    row = (await session.execute(stmt)).first()
    return row is not None


async def main() -> int:
    total_success = 0
    total_skip = 0
    total_fail = 0

    async with async_session_maker() as session:
        rows = (await session.execute(
            select(Photo.id, Photo.pet_id, Photo.storage_key)
            .order_by(Photo.id),
        )).all()
        logger.info("found %d photos to consider", len(rows))

        for photo_id, pet_id, storage_key in rows:
            if await _photo_has_embedding(session, photo_id):
                total_skip += 1
                logger.info(
                    "skip photo=%s pet=%s already has embedding",
                    photo_id, pet_id,
                )
                continue

            data = await _photo_bytes(storage_key)
            if data is None:
                total_fail += 1
                continue

            try:
                vec = await embed_image(data)
            except EmbeddingUnavailableError as e:
                logger.warning(
                    "embed fail photo=%s pet=%s err=%s",
                    photo_id, pet_id, e,
                )
                total_fail += 1
                continue

            await add_embedding(
                session,
                pet_id=pet_id,
                photo_id=photo_id,
                vector=vec,
                source=EmbeddingSource.USER_UPLOADED,
            )
            total_success += 1
            logger.info(
                "ok photo=%s pet=%s dim=%d",
                photo_id, pet_id, len(vec),
            )

    logger.info(
        "done: success=%d skipped=%d failed=%d",
        total_success, total_skip, total_fail,
    )
    return 0 if total_fail == 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
