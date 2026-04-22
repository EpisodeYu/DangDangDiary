"""Classify-feedback service (Phase 2 Step 3 Option A).

Thin wrapper around the ``classify_feedbacks`` table so the photo upload
route doesn't import the ORM directly. Kept separate from
``pet_centroid`` so the centroid decision logic stays pure (no writes
against unrelated tables during a classify call).
"""
from __future__ import annotations

import logging

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.classify_feedback import ClassifyFeedback
from app.utils.time import utcnow


logger = logging.getLogger(__name__)


async def record_correction(
    db: AsyncSession,
    *,
    user_id: int,
    from_pet_id: int | None,
    to_pet_id: int,
    photo_id: int | None,
    top1_similarity: float | None,
) -> ClassifyFeedback:
    """Append one feedback row. Caller is responsible for committing
    the surrounding transaction (we only ``flush`` here so the row
    participates in the enclosing upload transaction and is rolled back
    together with it if that upload ultimately fails).

    ``from_pet_id`` may be ``None`` when the model offered no suggestion
    (empty pool / below threshold). In that case the row documents a
    cold-start pick rather than a correction, which is still useful for
    sample-volume analysis.
    """
    row = ClassifyFeedback(
        user_id=user_id,
        from_pet_id=from_pet_id,
        to_pet_id=to_pet_id,
        photo_id=photo_id,
        top1_similarity=top1_similarity,
        created_at=utcnow(),
    )
    db.add(row)
    await db.flush()
    return row
