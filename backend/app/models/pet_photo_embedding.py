"""Phase 2 Step 3 — pet photo embedding storage.

Each row is a single "this photo/sample looked like pet X" vector the
classify endpoint (and the upload → backfill path) compare new uploads
against.

The column dimension is driven by `settings.DASHSCOPE_EMBEDDING_DIMENSION`;
the `tongyi-embedding-vision-plus` model on the Singapore region emits
1152 floats. Changing the setting requires a new migration — mismatched
dims produce a length-check failure inside `services/embedding.py` before
the write ever hits the DB.
"""
from __future__ import annotations

import enum
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import BigInteger, DateTime, Enum, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.config import settings
from app.database import Base
from app.utils.time import utcnow


EMBEDDING_DIM: int = settings.DASHSCOPE_EMBEDDING_DIMENSION


class EmbeddingSource(str, enum.Enum):
    """Why this embedding exists.

    ``PET_AVATAR`` is reserved for a future avatar-bootstrapping flow;
    it is never written by the current code paths but the enum value
    is already present in the DB to keep future migrations additive.
    """

    PET_AVATAR = "pet_avatar"
    USER_UPLOADED = "user_uploaded"
    USER_CORRECTED = "user_corrected"


class PetPhotoEmbedding(Base):
    __tablename__ = "pet_photo_embeddings"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("pets.id"), nullable=False, index=True,
    )
    # Nullable so bootstrap samples (pre-photo or post-photo-delete) can
    # live in the pool without a cascading FK. On photo delete we only
    # SET NULL (see migration) — the embedding is still a useful sample.
    photo_id: Mapped[int | None] = mapped_column(
        BigInteger, ForeignKey("photos.id", ondelete="SET NULL"), nullable=True,
    )
    embedding: Mapped[list[float]] = mapped_column(Vector(EMBEDDING_DIM), nullable=False)
    # `values_callable` forces SQLAlchemy to persist the enum *values*
    # (``user_uploaded`` / …) rather than the default *names*
    # (``USER_UPLOADED``). The Postgres enum type defined in the
    # step-3 migration only knows the lowercase value form, so without
    # this override every INSERT fails with
    # ``InvalidTextRepresentationError: invalid input value for enum
    # embeddingsource: "USER_UPLOADED"``.
    source: Mapped[EmbeddingSource] = mapped_column(
        Enum(
            EmbeddingSource,
            name="embeddingsource",
            values_callable=lambda enum_cls: [e.value for e in enum_cls],
        ),
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)
