"""Phase 2 Step 3 "Option A" — classify correction feedback log.

Every time a user overrides the model's suggested pet chip on the
record-screen (``classify_source=corrected``), we write one row here so
we can later:

* Spot reliably-confused pet pairs (e.g. two similar orange cats) and
  prompt the user to add more bootstrap samples.
* Re-tune ``CLASSIFY_SIM_TOP1_MIN`` / ``CLASSIFY_SIM_MARGIN_MIN`` from
  real distributions instead of the paper defaults.
* In a future iteration, feed the (from_pet_id, to_pet_id) pair into a
  soft-negative down-weighting rule.

This is intentionally *structured* (not just ``logger.info``) so SQL
aggregations can run against it without re-parsing log lines.

``from_pet_id`` is nullable because the model may have offered no chip
at all (empty pool / low confidence → ``pet_id: null`` on the classify
response). In that case the user picked the chip from scratch; it's
still a useful positive signal even though no override happened.
"""
from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Float, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base
from app.utils.time import utcnow


class ClassifyFeedback(Base):
    __tablename__ = "classify_feedbacks"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=False, index=True,
    )
    # NULL ⇒ the model had no suggestion (empty pool / below threshold).
    from_pet_id: Mapped[int | None] = mapped_column(
        BigInteger, ForeignKey("pets.id", ondelete="SET NULL"), nullable=True, index=True,
    )
    # What the user ultimately picked. Always present — we only insert
    # a row when an upload actually succeeded onto a pet.
    to_pet_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("pets.id", ondelete="CASCADE"), nullable=False, index=True,
    )
    # The photo that was uploaded alongside the correction. SET NULL on
    # photo delete because the feedback is still diagnostically useful
    # after a user purges the source image.
    photo_id: Mapped[int | None] = mapped_column(
        BigInteger, ForeignKey("photos.id", ondelete="SET NULL"), nullable=True,
    )
    # Top-1 cosine similarity the classify endpoint reported for
    # ``from_pet_id`` at the moment of suggestion, or NULL when the
    # frontend didn't pass it through (older clients, or no suggestion
    # was made). Recorded for distribution analysis.
    top1_similarity: Mapped[float | None] = mapped_column(Float, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, nullable=False, index=True,
    )
