"""Unit tests for ``app.services.pet_centroid``.

Uses the existing SQLite-based test engine + session fixtures — the
service intentionally branches on dialect and computes cosine
similarity in Python on SQLite, so the decision rule is fully
exercised without a running Postgres.
"""
from __future__ import annotations

import math

import pytest
import pytest_asyncio
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.config import settings
from app.models.pet import MemberRole, Pet, PetMember, PetType
from app.models.pet_photo_embedding import EmbeddingSource, PetPhotoEmbedding
from app.models.user import User
from app.services import pet_centroid
from tests._sqlite_compat import apply_sqlite_compat


pytestmark = pytest.mark.asyncio


# --------------------------------------------------------- fixtures


@pytest_asyncio.fixture()
async def engine():
    apply_sqlite_compat()
    from sqlalchemy.ext.asyncio import create_async_engine

    from app.database import Base
    import app.models  # noqa: F401 ensure model registration

    eng = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with eng.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield eng
    await eng.dispose()


@pytest_asyncio.fixture()
async def session(engine):
    sm = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        yield s


async def _make_user_and_pet(
    s: AsyncSession,
    *,
    phone: str,
    pet_name: str,
    role: MemberRole = MemberRole.OWNER,
) -> tuple[int, int]:
    user = User(phone=phone)
    s.add(user)
    await s.flush()
    pet = Pet(
        owner_id=user.id,
        name=pet_name,
        pet_type=PetType.CAT,
        invite_code=f"inv-{phone[-4:]}-{pet_name[:3]}",
    )
    s.add(pet)
    await s.flush()
    member = PetMember(pet_id=pet.id, user_id=user.id, role=role)
    s.add(member)
    await s.flush()
    await s.commit()
    return user.id, pet.id


def _unit_vec(seed: int, dim: int) -> list[float]:
    """Generate a deterministic unit vector biased toward one dimension.

    Useful to build specific cosine-similarity values: two vectors with
    the same `seed` have similarity 1.0; different seeds give ~0
    overlap, which we nudge with `_blend` below.
    """
    v = [0.0] * dim
    v[seed % dim] = 1.0
    return v


def _blend(a: list[float], b: list[float], alpha: float) -> list[float]:
    """Return a unit vector pointing `alpha` of the way from `a` to `b`.

    If `a` and `b` are orthogonal unit vectors, cosine(result, a) =
    (1 - alpha) / sqrt((1 - alpha)^2 + alpha^2).
    """
    out = [(1 - alpha) * x + alpha * y for x, y in zip(a, b)]
    norm = math.sqrt(sum(x * x for x in out))
    if norm == 0:
        return out
    return [x / norm for x in out]


# ------------------------------------------------- list_editor_pet_ids


async def test_list_editor_pet_ids_excludes_viewer(session):
    s = session
    user_id, owned_pet_id = await _make_user_and_pet(
        s, phone="13800000001", pet_name="owned",
    )
    # Viewer on a different pet (via another owner)
    other_uid, other_pid = await _make_user_and_pet(
        s, phone="13800000099", pet_name="alien",
    )
    s.add(PetMember(pet_id=other_pid, user_id=user_id, role=MemberRole.VIEWER))
    await s.commit()

    ids = await pet_centroid.list_editor_pet_ids(s, user_id)
    assert ids == [owned_pet_id]


async def test_list_editor_pet_ids_includes_editor(session):
    s = session
    user_id, owned_pet_id = await _make_user_and_pet(
        s, phone="13800000002", pet_name="owned",
    )
    _, shared_pid = await _make_user_and_pet(
        s, phone="13800000098", pet_name="shared",
    )
    s.add(PetMember(pet_id=shared_pid, user_id=user_id, role=MemberRole.EDITOR))
    await s.commit()

    ids = set(await pet_centroid.list_editor_pet_ids(s, user_id))
    assert ids == {owned_pet_id, shared_pid}


# -------------------------------------------------------- classify


async def test_classify_empty_pool_returns_null(session):
    s = session
    user_id, _ = await _make_user_and_pet(
        s, phone="13800000010", pet_name="empty",
    )
    vec = _unit_vec(3, settings.DASHSCOPE_EMBEDDING_DIMENSION)
    result = await pet_centroid.classify(s, user_id, vec)
    assert result.pet_id is None
    assert result.confidence is None


async def test_classify_no_editor_pets_returns_null(session):
    s = session
    # Create a user but no pets.
    u = User(phone="13800000011")
    s.add(u)
    await s.flush()
    await s.commit()
    vec = _unit_vec(0, settings.DASHSCOPE_EMBEDDING_DIMENSION)
    result = await pet_centroid.classify(s, u.id, vec)
    assert result.pet_id is None


async def test_classify_single_pet_high_similarity_hits(session):
    s = session
    user_id, pet_id = await _make_user_and_pet(
        s, phone="13800000020", pet_name="solo",
    )
    dim = settings.DASHSCOPE_EMBEDDING_DIMENSION
    sample = _unit_vec(5, dim)
    await pet_centroid.add_embedding(
        s,
        pet_id=pet_id,
        photo_id=None,
        vector=sample,
        source=EmbeddingSource.USER_CORRECTED,
    )

    # Query with the exact same vector → similarity 1.0 → hit.
    result = await pet_centroid.classify(s, user_id, sample)
    assert result.pet_id == pet_id
    assert result.confidence is not None
    assert result.confidence >= 0.99


async def test_classify_margin_rule_rejects_when_top2_close(session):
    s = session
    user_id, pet_a = await _make_user_and_pet(
        s, phone="13800000030", pet_name="miao",
    )
    # Second pet shared as EDITOR so both are candidates.
    _, pet_b = await _make_user_and_pet(
        s, phone="13800000031", pet_name="juzi",
    )
    s.add(PetMember(pet_id=pet_b, user_id=user_id, role=MemberRole.EDITOR))
    await s.commit()

    dim = settings.DASHSCOPE_EMBEDDING_DIMENSION
    base = _unit_vec(0, dim)
    other = _unit_vec(1, dim)

    # pet_a has a reference vector = base
    await pet_centroid.add_embedding(
        s, pet_id=pet_a, photo_id=None,
        vector=base, source=EmbeddingSource.USER_CORRECTED,
    )
    # pet_b has a reference that's a tiny blend of base+other, so it
    # almost matches `base` too — margin collapses below the threshold.
    tiny = _blend(base, other, 0.02)
    await pet_centroid.add_embedding(
        s, pet_id=pet_b, photo_id=None,
        vector=tiny, source=EmbeddingSource.USER_CORRECTED,
    )

    # Classify with `base` — top1 = pet_a (sim 1.0), top2 = pet_b (sim ~0.9998)
    # → margin << CLASSIFY_SIM_MARGIN_MIN → null.
    result = await pet_centroid.classify(s, user_id, base)
    assert result.pet_id is None
    assert result.confidence is None


async def test_classify_hits_when_margin_is_clear(session):
    s = session
    user_id, pet_a = await _make_user_and_pet(
        s, phone="13800000040", pet_name="miao",
    )
    _, pet_b = await _make_user_and_pet(
        s, phone="13800000041", pet_name="juzi",
    )
    s.add(PetMember(pet_id=pet_b, user_id=user_id, role=MemberRole.EDITOR))
    await s.commit()

    dim = settings.DASHSCOPE_EMBEDDING_DIMENSION
    base = _unit_vec(0, dim)
    other = _unit_vec(1, dim)  # orthogonal to base

    await pet_centroid.add_embedding(
        s, pet_id=pet_a, photo_id=None,
        vector=base, source=EmbeddingSource.USER_CORRECTED,
    )
    await pet_centroid.add_embedding(
        s, pet_id=pet_b, photo_id=None,
        vector=other, source=EmbeddingSource.USER_CORRECTED,
    )

    # Query exactly equals pet_a's reference → top1 sim = 1.0, top2 sim
    # = 0.0 → clear win.
    result = await pet_centroid.classify(s, user_id, base)
    assert result.pet_id == pet_a
    assert result.confidence is not None
    assert result.confidence >= 0.99


async def test_classify_top1_below_threshold_returns_null(session, monkeypatch):
    s = session
    user_id, pet_a = await _make_user_and_pet(
        s, phone="13800000050", pet_name="solo",
    )

    dim = settings.DASHSCOPE_EMBEDDING_DIMENSION
    base = _unit_vec(0, dim)
    other = _unit_vec(1, dim)

    await pet_centroid.add_embedding(
        s, pet_id=pet_a, photo_id=None,
        vector=base, source=EmbeddingSource.USER_CORRECTED,
    )

    # Query halfway between base and an orthogonal direction → sim ~0.707
    blend = _blend(base, other, 0.5)
    result = await pet_centroid.classify(s, user_id, blend)
    # 0.707 < default SIM_TOP1_MIN (0.78) → null
    assert result.pet_id is None


async def test_classify_collapses_per_pet_best_similarity(session):
    """Multiple rows per pet: the service must take the best, not the
    first / average."""
    s = session
    user_id, pet_a = await _make_user_and_pet(
        s, phone="13800000060", pet_name="multi",
    )
    dim = settings.DASHSCOPE_EMBEDDING_DIMENSION
    base = _unit_vec(0, dim)
    far = _unit_vec(1, dim)

    # One close sample, one far sample — the close one must be the
    # sim the decision sees.
    await pet_centroid.add_embedding(
        s, pet_id=pet_a, photo_id=None,
        vector=far, source=EmbeddingSource.USER_UPLOADED,
    )
    await pet_centroid.add_embedding(
        s, pet_id=pet_a, photo_id=None,
        vector=base, source=EmbeddingSource.USER_CORRECTED,
    )

    result = await pet_centroid.classify(s, user_id, base)
    assert result.pet_id == pet_a
    assert result.confidence is not None
    assert result.confidence >= 0.99


async def test_classify_viewer_pet_excluded_from_candidates(session):
    s = session
    user_id, owner_pet = await _make_user_and_pet(
        s, phone="13800000070", pet_name="mine",
    )
    _, other_pet = await _make_user_and_pet(
        s, phone="13800000071", pet_name="theirs",
    )
    s.add(PetMember(pet_id=other_pet, user_id=user_id, role=MemberRole.VIEWER))
    await s.commit()

    dim = settings.DASHSCOPE_EMBEDDING_DIMENSION
    base = _unit_vec(0, dim)
    far = _unit_vec(1, dim)

    # Strong signal for the viewer pet, weak for the owner pet → the
    # decision must still refuse to surface the viewer pet.
    await pet_centroid.add_embedding(
        s, pet_id=other_pet, photo_id=None,
        vector=base, source=EmbeddingSource.USER_CORRECTED,
    )
    await pet_centroid.add_embedding(
        s, pet_id=owner_pet, photo_id=None,
        vector=far, source=EmbeddingSource.USER_CORRECTED,
    )

    result = await pet_centroid.classify(s, user_id, base)
    # Owner pet is the only candidate; sim to `far` is ~0 → null.
    assert result.pet_id is None


# ------------------------------------------------------- add_embedding


async def test_add_embedding_round_trip(session):
    s = session
    _, pet_id = await _make_user_and_pet(
        s, phone="13800000080", pet_name="roundtrip",
    )
    dim = settings.DASHSCOPE_EMBEDDING_DIMENSION
    vec = _unit_vec(7, dim)
    row = await pet_centroid.add_embedding(
        s, pet_id=pet_id, photo_id=None,
        vector=vec, source=EmbeddingSource.USER_UPLOADED,
    )
    assert row.id is not None
    assert row.pet_id == pet_id
    assert row.source == EmbeddingSource.USER_UPLOADED
    assert len(row.embedding) == dim
