"""Pet centroid lookup + classify decision (Phase 2 Step 3).

Given a fresh photo embedding, compare it against every
``pet_photo_embeddings`` row belonging to a pet the caller has
``EDITOR`` access to, and return a ``(pet_id, confidence)`` tuple using
a top-1 + margin rule.

On Postgres we use the native ``pgvector`` ``<=>`` cosine-distance
operator and only pull the top-20 rows back. On SQLite (the test
harness) we fall back to loading the matching rows and computing
cosine similarity in Python — correct, just slower, which is fine
because the test suite never exceeds a handful of rows.
"""
from __future__ import annotations

import logging
import math
from dataclasses import dataclass

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models.pet import MemberRole, PetMember
from app.models.pet_photo_embedding import EmbeddingSource, PetPhotoEmbedding
from app.utils.time import utcnow


logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class ClassifyResult:
    """Top-level outcome of one classify call.

    ``pet_id`` / ``confidence`` are both ``None`` when the caller has
    no editable pets, the embedding pool is empty, or the Top-1 vs
    Top-2 decision falls below the configured thresholds.
    """

    pet_id: int | None
    confidence: float | None


async def list_editor_pet_ids(db: AsyncSession, user_id: int) -> list[int]:
    """All pet ids the user can *write* to (OWNER or EDITOR).

    VIEWER-only pets are intentionally excluded — even if the embedding
    matches, the user cannot upload, so surfacing the candidate would
    only confuse them.
    """
    stmt = select(PetMember.pet_id).where(
        PetMember.user_id == user_id,
        PetMember.role.in_([MemberRole.OWNER, MemberRole.EDITOR]),
    )
    rows = await db.execute(stmt)
    return [r[0] for r in rows.all()]


def _cosine_similarity(a: list[float], b: list[float]) -> float:
    """Plain cosine similarity on Python lists. Used only for SQLite tests.

    Both vectors are assumed to be the same non-zero length — the
    embedding service enforces that on write.
    """
    if not a or not b or len(a) != len(b):
        return 0.0
    dot = 0.0
    na = 0.0
    nb = 0.0
    for x, y in zip(a, b):
        dot += x * y
        na += x * x
        nb += y * y
    if na == 0.0 or nb == 0.0:
        return 0.0
    return dot / (math.sqrt(na) * math.sqrt(nb))


async def _top_rows_pgvector(
    db: AsyncSession,
    *,
    pet_ids: list[int],
    vector: list[float],
    limit: int,
) -> list[tuple[int, float]]:
    """Top-N (pet_id, sim) rows via pgvector's ``<=>`` operator."""
    stmt = (
        select(
            PetPhotoEmbedding.pet_id,
            (1 - PetPhotoEmbedding.embedding.cosine_distance(vector)).label("sim"),
        )
        .where(PetPhotoEmbedding.pet_id.in_(pet_ids))
        .order_by(PetPhotoEmbedding.embedding.cosine_distance(vector))
        .limit(limit)
    )
    rows = (await db.execute(stmt)).all()
    return [(int(pid), float(sim)) for pid, sim in rows]


async def _top_rows_python(
    db: AsyncSession,
    *,
    pet_ids: list[int],
    vector: list[float],
    limit: int,
) -> list[tuple[int, float]]:
    """SQLite fallback: compute cosine similarity in Python."""
    stmt = (
        select(PetPhotoEmbedding.pet_id, PetPhotoEmbedding.embedding)
        .where(PetPhotoEmbedding.pet_id.in_(pet_ids))
    )
    rows = (await db.execute(stmt)).all()
    scored: list[tuple[int, float]] = []
    for pid, emb in rows:
        sim = _cosine_similarity(vector, list(emb) if emb is not None else [])
        scored.append((int(pid), sim))
    scored.sort(key=lambda x: -x[1])
    return scored[:limit]


async def classify(
    db: AsyncSession,
    user_id: int,
    vector: list[float],
) -> ClassifyResult:
    """Map ``vector`` to one of the user's pets (or ``None``).

    Decision rule (see docs/phase2-step3 §5.2):
        hit iff  top1_sim >= CLASSIFY_SIM_TOP1_MIN
             and (top1_sim - top2_sim) >= CLASSIFY_SIM_MARGIN_MIN
    where each pet's similarity is the *best* similarity among its
    stored embedding rows.
    """
    pet_ids = await list_editor_pet_ids(db, user_id)
    if not pet_ids:
        return ClassifyResult(pet_id=None, confidence=None)

    dialect = db.bind.dialect.name if db.bind is not None else ""
    if dialect == "postgresql":
        rows = await _top_rows_pgvector(
            db, pet_ids=pet_ids, vector=vector, limit=20,
        )
    else:
        rows = await _top_rows_python(
            db, pet_ids=pet_ids, vector=vector, limit=20,
        )

    if not rows:
        return ClassifyResult(pet_id=None, confidence=None)

    # Collapse to per-pet best similarity.
    best_by_pet: dict[int, float] = {}
    for pid, sim in rows:
        if pid not in best_by_pet or sim > best_by_pet[pid]:
            best_by_pet[pid] = sim

    ranked = sorted(best_by_pet.items(), key=lambda x: -x[1])
    top1_pet, top1_sim = ranked[0]
    top2_sim = ranked[1][1] if len(ranked) > 1 else 0.0

    if (
        top1_sim >= settings.CLASSIFY_SIM_TOP1_MIN
        and (top1_sim - top2_sim) >= settings.CLASSIFY_SIM_MARGIN_MIN
    ):
        return ClassifyResult(pet_id=top1_pet, confidence=round(float(top1_sim), 3))
    return ClassifyResult(pet_id=None, confidence=None)


async def add_embedding(
    db: AsyncSession,
    *,
    pet_id: int,
    photo_id: int | None,
    vector: list[float],
    source: EmbeddingSource,
) -> PetPhotoEmbedding:
    """Append one row to the embedding pool. Commits its own transaction."""
    row = PetPhotoEmbedding(
        pet_id=pet_id,
        photo_id=photo_id,
        embedding=vector,
        source=source,
        created_at=utcnow(),
    )
    db.add(row)
    await db.flush()
    await db.commit()
    await db.refresh(row)
    return row
