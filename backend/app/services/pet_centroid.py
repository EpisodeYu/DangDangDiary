"""Pet centroid lookup + classify decision (Phase 2 Step 3).

Given a fresh photo embedding, compare it against every
``pet_photo_embeddings`` row belonging to a pet the caller has
``EDITOR`` access to, and return a ``(pet_id, confidence)`` tuple using
a top-1 + margin rule.

On Postgres we use the native ``pgvector`` ``<=>`` cosine-distance
operator and only pull the top-N rows back. On SQLite (the test
harness) we fall back to loading the matching rows and computing
cosine similarity in Python — correct, just slower, which is fine
because the test suite never exceeds a handful of rows.

Option A (see docs/phase2-step3 §Option A) adds two things on top of
the original design:

1. **Source-aware ranking**: rows with ``source == USER_CORRECTED`` get
   a small additive bonus to their cosine similarity before the per-pet
   max / Top-1 / margin rule runs. User-flagged positives are a
   stronger signal than arbitrary uploads, so they should tip
   otherwise-ambiguous decisions.
2. **Near-duplicate collapse**: ``add_embedding`` skips an insert (or
   upgrades the existing row's source) when the incoming vector is
   already ≥ ``CLASSIFY_DEDUP_SIMILARITY`` similar to a recent row for
   the same pet. Prevents "same photo uploaded twice" and burst
   sessions (10 nearly-identical frames) from poisoning the decision
   rule's "per-pet max" by stacking one pet's sample count.
"""
from __future__ import annotations

import logging
import math
from dataclasses import dataclass
from datetime import timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.models.pet import MemberRole, PetMember
from app.models.pet_photo_embedding import EmbeddingSource, PetPhotoEmbedding
from app.utils.time import utcnow


logger = logging.getLogger(__name__)


# Rank the three embedding sources by "how much we trust this sample".
# Used by the dedup-collapse path to decide whether a new write should
# *upgrade* an existing row's source (e.g. an older USER_UPLOADED row
# becoming USER_CORRECTED when the user re-confirms the chip).
_SOURCE_RANK: dict[EmbeddingSource, int] = {
    EmbeddingSource.PET_AVATAR: 0,
    EmbeddingSource.USER_UPLOADED: 1,
    EmbeddingSource.USER_CORRECTED: 2,
}


def _source_rank(source: EmbeddingSource) -> int:
    return _SOURCE_RANK.get(source, 0)


def _source_bonus(source: EmbeddingSource) -> float:
    """Additive similarity bonus for a given source.

    Only ``USER_CORRECTED`` is boosted — ``PET_AVATAR`` is a future
    bootstrap channel we don't fully trust yet (may be a stock icon),
    and ``USER_UPLOADED`` is our neutral baseline.
    """
    if source == EmbeddingSource.USER_CORRECTED:
        return float(settings.CLASSIFY_CORRECTED_BOOST)
    return 0.0


@dataclass(frozen=True)
class ClassifyResult:
    """Top-level outcome of one classify call.

    ``pet_id`` / ``confidence`` are both ``None`` when the caller has
    no editable pets, the embedding pool is empty, or the Top-1 vs
    Top-2 decision falls below the configured thresholds.

    ``confidence`` is the *boosted* top-1 similarity clamped to ``[0, 1]``.
    Callers that want the raw, unboosted similarity for logging should
    pull it from the feedback table (``top1_similarity``) which records
    the pre-boost value.
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
) -> list[tuple[int, float, EmbeddingSource]]:
    """Top-N (pet_id, sim, source) rows via pgvector's ``<=>`` operator.

    The ORDER BY still uses raw cosine distance so pgvector's IVFFlat
    index is actually used. The boost is applied in-Python afterwards;
    with ``CLASSIFY_CORRECTED_BOOST=0.02`` and ``limit=30`` the chance
    of a boosted row falling outside the Top-N that the rule would
    otherwise have picked is negligible.
    """
    stmt = (
        select(
            PetPhotoEmbedding.pet_id,
            (1 - PetPhotoEmbedding.embedding.cosine_distance(vector)).label("sim"),
            PetPhotoEmbedding.source,
        )
        .where(PetPhotoEmbedding.pet_id.in_(pet_ids))
        .order_by(PetPhotoEmbedding.embedding.cosine_distance(vector))
        .limit(limit)
    )
    rows = (await db.execute(stmt)).all()
    return [(int(pid), float(sim), src) for pid, sim, src in rows]


async def _top_rows_python(
    db: AsyncSession,
    *,
    pet_ids: list[int],
    vector: list[float],
    limit: int,
) -> list[tuple[int, float, EmbeddingSource]]:
    """SQLite fallback: compute cosine similarity in Python."""
    stmt = (
        select(
            PetPhotoEmbedding.pet_id,
            PetPhotoEmbedding.embedding,
            PetPhotoEmbedding.source,
        )
        .where(PetPhotoEmbedding.pet_id.in_(pet_ids))
    )
    rows = (await db.execute(stmt)).all()
    scored: list[tuple[int, float, EmbeddingSource]] = []
    for pid, emb, src in rows:
        sim = _cosine_similarity(vector, list(emb) if emb is not None else [])
        scored.append((int(pid), sim, src))
    scored.sort(key=lambda x: -x[1])
    return scored[:limit]


# Pull a few more rows than the original design's 20 so the per-source
# boost can reorder without risking a boosted row falling off the tail.
_TOP_ROW_LIMIT = 30


async def classify(
    db: AsyncSession,
    user_id: int,
    vector: list[float],
) -> ClassifyResult:
    """Map ``vector`` to one of the user's pets (or ``None``).

    Decision rule (Option A):
        1. Pull the Top-N nearest ``(pet_id, sim, source)`` rows among
           the caller's editable pets.
        2. For each row, compute ``boosted = sim + bonus(source)``.
        3. Collapse rows to one per pet by taking the *max boosted*
           similarity.
        4. Sort pets by that max and apply the Top-1 + margin rule:
               hit iff  top1 >= CLASSIFY_SIM_TOP1_MIN
                    and (top1 - top2) >= CLASSIFY_SIM_MARGIN_MIN
        5. Clamp the reported confidence to ``[0, 1]``.
    """
    pet_ids = await list_editor_pet_ids(db, user_id)
    if not pet_ids:
        return ClassifyResult(pet_id=None, confidence=None)

    dialect = db.bind.dialect.name if db.bind is not None else ""
    if dialect == "postgresql":
        rows = await _top_rows_pgvector(
            db, pet_ids=pet_ids, vector=vector, limit=_TOP_ROW_LIMIT,
        )
    else:
        rows = await _top_rows_python(
            db, pet_ids=pet_ids, vector=vector, limit=_TOP_ROW_LIMIT,
        )

    if not rows:
        return ClassifyResult(pet_id=None, confidence=None)

    # Collapse to per-pet best *boosted* similarity. Using the boosted
    # value for the max ensures a corrected-but-slightly-further sample
    # can out-rank an uncorrected-but-slightly-closer one for the same
    # pet, which is what we want.
    best_by_pet: dict[int, float] = {}
    for pid, sim, src in rows:
        boosted = sim + _source_bonus(src)
        if pid not in best_by_pet or boosted > best_by_pet[pid]:
            best_by_pet[pid] = boosted

    ranked = sorted(best_by_pet.items(), key=lambda x: -x[1])
    top1_pet, top1_boosted = ranked[0]
    top2_boosted = ranked[1][1] if len(ranked) > 1 else 0.0

    if (
        top1_boosted >= settings.CLASSIFY_SIM_TOP1_MIN
        and (top1_boosted - top2_boosted) >= settings.CLASSIFY_SIM_MARGIN_MIN
    ):
        confidence = max(0.0, min(1.0, float(top1_boosted)))
        return ClassifyResult(pet_id=top1_pet, confidence=round(confidence, 3))
    return ClassifyResult(pet_id=None, confidence=None)


async def _find_near_duplicate(
    db: AsyncSession,
    *,
    pet_id: int,
    vector: list[float],
) -> tuple[PetPhotoEmbedding, float] | None:
    """Return the closest recent embedding for the same pet if it's a
    near-duplicate, else ``None``.

    "Recent" = within ``CLASSIFY_DEDUP_WINDOW_DAYS``. Older rows are
    considered part of the permanent historical pool (seasonal
    variation, life-stage coverage) and never collapsed against.
    """
    threshold = float(settings.CLASSIFY_DEDUP_SIMILARITY)
    window_days = int(settings.CLASSIFY_DEDUP_WINDOW_DAYS)
    cutoff = utcnow() - timedelta(days=window_days)

    dialect = db.bind.dialect.name if db.bind is not None else ""
    if dialect == "postgresql":
        stmt = (
            select(
                PetPhotoEmbedding,
                (1 - PetPhotoEmbedding.embedding.cosine_distance(vector)).label("sim"),
            )
            .where(
                PetPhotoEmbedding.pet_id == pet_id,
                PetPhotoEmbedding.created_at >= cutoff,
            )
            .order_by(PetPhotoEmbedding.embedding.cosine_distance(vector))
            .limit(1)
        )
        row = (await db.execute(stmt)).first()
        if row is None:
            return None
        existing, sim = row[0], float(row[1])
        if sim >= threshold:
            return existing, sim
        return None

    stmt = (
        select(PetPhotoEmbedding)
        .where(
            PetPhotoEmbedding.pet_id == pet_id,
            PetPhotoEmbedding.created_at >= cutoff,
        )
    )
    existing_rows = (await db.execute(stmt)).scalars().all()
    best: tuple[PetPhotoEmbedding, float] | None = None
    for row in existing_rows:
        emb = list(row.embedding) if row.embedding is not None else []
        sim = _cosine_similarity(vector, emb)
        if best is None or sim > best[1]:
            best = (row, sim)
    if best is not None and best[1] >= threshold:
        return best
    return None


async def add_embedding(
    db: AsyncSession,
    *,
    pet_id: int,
    photo_id: int | None,
    vector: list[float],
    source: EmbeddingSource,
) -> PetPhotoEmbedding:
    """Append one row to the embedding pool, collapsing near-duplicates.

    Behaviour:

    * If a recent row for the same pet is ≥ ``CLASSIFY_DEDUP_SIMILARITY``
      similar to ``vector``, **no new row is inserted**.
    * The existing row's ``source`` is upgraded when the new write
      carries a higher-trust source (e.g. ``USER_UPLOADED`` →
      ``USER_CORRECTED``).
    * The existing row's ``photo_id`` is filled in iff it was previously
      ``NULL`` and the new write has one — keeping the strongest link
      available without overwriting a valid photo reference.
    * Commits its own transaction either way. Returns the row that now
      represents this sample (either the newly-inserted row or the
      collapsed-into existing row).
    """
    dup = await _find_near_duplicate(db, pet_id=pet_id, vector=vector)
    if dup is not None:
        existing, sim = dup
        prior_source = existing.source
        updated = False
        if _source_rank(source) > _source_rank(existing.source):
            existing.source = source
            updated = True
        if existing.photo_id is None and photo_id is not None:
            existing.photo_id = photo_id
            updated = True
        logger.info(
            "embedding dedup collapse pet=%s sim=%.4f existing_id=%s source=%s->%s",
            pet_id, sim, existing.id, prior_source.value, existing.source.value,
        )
        if updated:
            await db.commit()
            await db.refresh(existing)
        return existing

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
