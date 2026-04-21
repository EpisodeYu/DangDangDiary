"""Phase 2 Step 3 — ``POST /photos/classify`` + upload-embedding backfill tests.

Mocks ``app.services.embedding.embed_image`` so the DashScope network
is never reached. Seeds ``pet_photo_embeddings`` rows directly via the
test DB to exercise the decision rule for hit / low-margin / viewer
exclusion paths.
"""
from __future__ import annotations

import io
from unittest.mock import patch

import pytest
import pytest_asyncio
from PIL import Image
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

import app.models  # noqa: F401 ensure ORM models registered
from app.config import settings
from app.models.pet import MemberRole, PetMember
from app.models.pet_photo_embedding import EmbeddingSource, PetPhotoEmbedding
from app.services import embedding as embedding_mod
from app.services import pet_centroid as pet_centroid_mod

from tests.conftest import _mock_sms_send


pytestmark = pytest.mark.asyncio


DIM = settings.DASHSCOPE_EMBEDDING_DIMENSION


# ------------------------------------------------------- helpers


async def _login(c, phone: str, code: str = "123456"):
    with _mock_sms_send(code):
        await c.post("/auth/send-code", json={"phone": phone})
    resp = await c.post("/auth/login", json={"phone": phone, "code": code})
    return resp.json()["access_token"]


async def _create_pet(c, headers, *, name="咪咪", pet_type="cat") -> int:
    resp = await c.post(
        "/pets",
        json={"name": name, "pet_type": pet_type},
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


def _png_bytes(size: int = 128, color=(200, 100, 50)) -> bytes:
    """Return a tiny real PNG. The embedding path is mocked so the
    content doesn't matter — we only need the content_type check to
    pass at the API layer, which only inspects the declared MIME."""
    buf = io.BytesIO()
    Image.new("RGB", (size, size), color).save(buf, format="PNG")
    return buf.getvalue()


def _unit_vec(seed: int) -> list[float]:
    v = [0.0] * DIM
    v[seed % DIM] = 1.0
    return v


def _multipart_files(n: int):
    return [
        ("files", (f"p{i}.png", _png_bytes(), "image/png"))
        for i in range(n)
    ]


async def _seed_embedding(
    engine, *, pet_id: int, vector: list[float], source: EmbeddingSource,
):
    sm = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        row = PetPhotoEmbedding(
            pet_id=pet_id, photo_id=None,
            embedding=vector, source=source,
        )
        s.add(row)
        await s.commit()


class _EmbedPatch:
    """Context manager that patches ``embed_image`` at every usage site.

    Routers ``from ... import embed_image`` create module-local refs
    that a single ``patch.object(embedding_mod, ...)`` doesn't cover.
    Patch both the classify router and the photos router at once so
    tests work regardless of which code path the request hits.
    """

    def __init__(self, side_effect):
        self._se = side_effect
        self._patches: list = []

    def __enter__(self):
        self._patches = [
            patch("app.api.v1.classify.embed_image", side_effect=self._se),
            patch("app.api.v1.photos.embed_image", side_effect=self._se),
            patch.object(embedding_mod, "embed_image", side_effect=self._se),
        ]
        for p in self._patches:
            p.start()
        return self

    def __exit__(self, *exc):
        for p in self._patches:
            p.stop()
        return False


def _mock_embed_returning(vec_by_idx: dict[int, list[float]] | list[float]):
    """Return a patch context that replaces `embed_image` globally.

    If `vec_by_idx` is a list, every call returns the same vector.
    If it's a dict, the i-th unique call returns vec_by_idx[i].
    """
    if isinstance(vec_by_idx, list):
        async def _one(_data: bytes):
            return list(vec_by_idx)
        return _EmbedPatch(_one)

    counter = {"i": 0}

    async def _multi(_data: bytes):
        i = counter["i"]
        counter["i"] += 1
        if i in vec_by_idx:
            return list(vec_by_idx[i])
        # Fall back to orthogonal garbage — the decision rule will say no.
        return _unit_vec(9999 + i)

    return _EmbedPatch(_multi)


# --------------------------------------------- validation errors


async def test_classify_empty_files_rejected(client):
    c, _ = client
    token = await _login(c, "13800150001")
    headers = {"Authorization": f"Bearer {token}"}
    await _create_pet(c, headers)

    # httpx can't send a truly empty `files` list on a multipart form,
    # so we target the code path that triggers CLASSIFY_EMPTY by
    # sending no files at all. FastAPI turns a missing required Form
    # into a 400 via our validation handler (VALIDATION_ERROR). The
    # more interesting "empty list after receipt" is practically
    # unreachable via the client, so assert we at least 4xx the case.
    resp = await c.post("/photos/classify", headers=headers)
    assert resp.status_code == 400, resp.text


async def test_classify_too_many_rejected(client):
    c, _ = client
    token = await _login(c, "13800150002")
    headers = {"Authorization": f"Bearer {token}"}
    await _create_pet(c, headers)

    files = _multipart_files(settings.CLASSIFY_MAX_FILES + 1)
    resp = await c.post("/photos/classify", files=files, headers=headers)
    assert resp.status_code == 400
    assert resp.json()["code"] == "CLASSIFY_TOO_MANY"


async def test_classify_bad_mime_rejected(client):
    c, _ = client
    token = await _login(c, "13800150003")
    headers = {"Authorization": f"Bearer {token}"}
    await _create_pet(c, headers)

    files = [("files", ("clip.gif", b"GIF89a" + b"\x00" * 32, "image/gif"))]
    resp = await c.post("/photos/classify", files=files, headers=headers)
    assert resp.status_code == 400
    assert resp.json()["code"] == "CLASSIFY_BAD_MIME"


async def test_classify_too_large_rejected(client):
    c, _ = client
    token = await _login(c, "13800150004")
    headers = {"Authorization": f"Bearer {token}"}
    await _create_pet(c, headers)

    big = b"\x89PNG\r\n\x1a\n" + b"\x00" * (settings.CLASSIFY_MAX_FILE_BYTES + 10)
    files = [("files", ("huge.png", big, "image/png"))]
    resp = await c.post("/photos/classify", files=files, headers=headers)
    assert resp.status_code == 400
    assert resp.json()["code"] == "CLASSIFY_TOO_LARGE"


# ----------------------------------- soft-fail upstream outage


async def test_classify_embedding_unavailable_returns_nulls(client):
    c, _ = client
    token = await _login(c, "13800150010")
    headers = {"Authorization": f"Bearer {token}"}
    await _create_pet(c, headers)

    async def _raise(_):
        raise embedding_mod.EmbeddingUnavailableError("dashscope 500")

    with _EmbedPatch(_raise):
        resp = await c.post(
            "/photos/classify",
            files=_multipart_files(2),
            headers=headers,
        )
    assert resp.status_code == 200
    body = resp.json()
    assert len(body["results"]) == 2
    for r in body["results"]:
        assert r["pet_id"] is None
        assert r["confidence"] is None


# ----------------------------------- empty candidate pool


async def test_classify_no_pets_returns_null(client):
    c, _ = client
    token = await _login(c, "13800150020")
    headers = {"Authorization": f"Bearer {token}"}
    # Intentionally no pet created.

    with _mock_embed_returning(_unit_vec(0)):
        resp = await c.post(
            "/photos/classify",
            files=_multipart_files(1),
            headers=headers,
        )
    assert resp.status_code == 200
    body = resp.json()
    assert body["results"][0]["pet_id"] is None


# ----------------------------------- top-1 hit


async def test_classify_hits_top1(client, test_engine):
    c, _ = client
    token = await _login(c, "13800150030")
    headers = {"Authorization": f"Bearer {token}"}
    pet_a = await _create_pet(c, headers, name="咪咪")
    pet_b = await _create_pet(c, headers, name="橘子")

    base = _unit_vec(0)
    other = _unit_vec(1)
    await _seed_embedding(
        test_engine, pet_id=pet_a, vector=base,
        source=EmbeddingSource.USER_CORRECTED,
    )
    await _seed_embedding(
        test_engine, pet_id=pet_b, vector=other,
        source=EmbeddingSource.USER_CORRECTED,
    )

    # Upload embedding = `base` → top1 = pet_a, top2 = pet_b (0.0) → hit
    with _mock_embed_returning(base):
        resp = await c.post(
            "/photos/classify",
            files=_multipart_files(1),
            headers=headers,
        )
    assert resp.status_code == 200
    r = resp.json()["results"][0]
    assert r["pet_id"] == pet_a
    assert r["confidence"] is not None and r["confidence"] >= 0.99


# --------------------------- low margin → null decision


async def test_classify_low_margin_returns_null(client, test_engine):
    c, _ = client
    token = await _login(c, "13800150040")
    headers = {"Authorization": f"Bearer {token}"}
    pet_a = await _create_pet(c, headers, name="咪咪")
    pet_b = await _create_pet(c, headers, name="橘子")

    # Two pets with nearly-identical references → Top-1 / Top-2 very
    # close → margin < CLASSIFY_SIM_MARGIN_MIN → null.
    import math
    base = _unit_vec(0)
    other = _unit_vec(1)
    alpha = 0.02
    nearly_same = [
        (1 - alpha) * x + alpha * y for x, y in zip(base, other)
    ]
    norm = math.sqrt(sum(v * v for v in nearly_same))
    nearly_same = [v / norm for v in nearly_same]

    await _seed_embedding(
        test_engine, pet_id=pet_a, vector=base,
        source=EmbeddingSource.USER_CORRECTED,
    )
    await _seed_embedding(
        test_engine, pet_id=pet_b, vector=nearly_same,
        source=EmbeddingSource.USER_CORRECTED,
    )

    with _mock_embed_returning(base):
        resp = await c.post(
            "/photos/classify",
            files=_multipart_files(1),
            headers=headers,
        )
    assert resp.status_code == 200
    assert resp.json()["results"][0]["pet_id"] is None


# --------------------------- viewer pet not in candidate set


async def test_classify_viewer_pet_excluded(client, test_engine):
    c, _ = client
    token_a = await _login(c, "13800150050")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet_a = await _create_pet(c, headers_a, name="mine")

    token_b = await _login(c, "13800150051")
    headers_b = {"Authorization": f"Bearer {token_b}"}
    pet_b = await _create_pet(c, headers_b, name="theirs")

    # User A becomes VIEWER on pet_b.
    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        # Figure out user_a's id via /auth/me
        pass
    # We don't have a `/auth/me` shortcut here; the JWT 'sub' is the user
    # id, but decoding it server-side requires settings. Simpler path:
    # add a PetMember row for pet_b with the user-id of A. We can derive
    # A's id by creating a fresh row & reading it back from the DB.
    # Easier: use an SQL insert with the user id discovered via the
    # `pets` endpoint. But PetMember needs the user_id. Let's fetch
    # via the DB.
    async with sm() as s:
        from app.models.pet import Pet as _Pet
        r = await s.execute(select(_Pet).where(_Pet.id == pet_a))
        owner_a_user_id = r.scalar_one().owner_id
        s.add(PetMember(
            pet_id=pet_b, user_id=owner_a_user_id, role=MemberRole.VIEWER,
        ))
        await s.commit()

    base = _unit_vec(0)
    other = _unit_vec(1)
    # Strong signal for viewer pet, weak for owner pet → must still
    # refuse to surface the viewer pet.
    await _seed_embedding(
        test_engine, pet_id=pet_b, vector=base,
        source=EmbeddingSource.USER_CORRECTED,
    )
    await _seed_embedding(
        test_engine, pet_id=pet_a, vector=other,
        source=EmbeddingSource.USER_CORRECTED,
    )

    with _mock_embed_returning(base):
        resp = await c.post(
            "/photos/classify",
            files=_multipart_files(1),
            headers=headers_a,
        )
    assert resp.status_code == 200
    # Owner pet is the only candidate; sim to `other` is 0 → null.
    assert resp.json()["results"][0]["pet_id"] is None


# --------------------------- preserves caller order


async def test_classify_results_keep_file_index_order(client, test_engine):
    c, _ = client
    token = await _login(c, "13800150060")
    headers = {"Authorization": f"Bearer {token}"}
    pet_a = await _create_pet(c, headers, name="咪咪")

    base = _unit_vec(0)
    await _seed_embedding(
        test_engine, pet_id=pet_a, vector=base,
        source=EmbeddingSource.USER_CORRECTED,
    )

    # All three classified — use the same returned vector so the
    # decision for each is identical, we just want to see file_index
    # stable and complete.
    with _mock_embed_returning(base):
        resp = await c.post(
            "/photos/classify",
            files=_multipart_files(3),
            headers=headers,
        )
    assert resp.status_code == 200
    results = resp.json()["results"]
    assert [r["file_index"] for r in results] == [0, 1, 2]


# ========================================================================
# Upload path: classify_source drives the backfilled EmbeddingSource value.
# ========================================================================


def _upload_files(n: int):
    return [
        ("files", (f"u{i}.jpg", b"\xff\xd8\xff\xe0" + b"\x00" * 128, "image/jpeg"))
        for i in range(n)
    ]


def _upload_stub():
    counter = {"i": 0}

    def _inner(pet_id: int, file_data: bytes, content_type: str):
        i = counter["i"]
        counter["i"] += 1
        return (
            f"{pet_id}/ok_{i}.jpg",
            f"{pet_id}/ok_{i}_thumb.jpg",
            f"{pet_id}/ok_{i}_thumb_sm.jpg",
        )

    return _inner


async def _fetch_embeddings(engine, pet_id: int):
    sm = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        rows = await s.execute(
            select(PetPhotoEmbedding).where(PetPhotoEmbedding.pet_id == pet_id)
        )
        return rows.scalars().all()


async def test_upload_with_corrected_source_marks_embedding(client, test_engine):
    c, _ = client
    token = await _login(c, "13800150070")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    vec = _unit_vec(3)
    data = {
        "taken_at": ["2024-01-15"],
        "classify_source": ["corrected"],
    }

    # `aupload_photo` offloads to thread → patch the sync helper.
    # Also route the background add_embedding writes through the test
    # engine so we can read them back.
    test_sm = async_sessionmaker(
        test_engine, class_=AsyncSession, expire_on_commit=False,
    )
    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def _fake_maker():
        async with test_sm() as s:
            yield s

    async def _fake_embed(_):
        return vec

    with _EmbedPatch(_fake_embed), patch(
        "app.services.storage.upload_photo", side_effect=_upload_stub(),
    ), patch(
        "app.api.v1.photos.async_session_maker", _fake_maker,
    ):
        resp = await c.post(
            f"/pets/{pet_id}/photos",
            files=_upload_files(1),
            data=data,
            headers=headers,
        )
    assert resp.status_code == 200, resp.text
    assert resp.json()["success_count"] == 1

    rows = await _fetch_embeddings(test_engine, pet_id)
    assert len(rows) == 1
    assert rows[0].source == EmbeddingSource.USER_CORRECTED
    assert len(rows[0].embedding) == DIM


async def test_upload_defaults_to_auto_source(client, test_engine):
    c, _ = client
    token = await _login(c, "13800150071")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    vec = _unit_vec(4)
    data = {"taken_at": ["2024-02-15"]}  # no classify_source field

    test_sm = async_sessionmaker(
        test_engine, class_=AsyncSession, expire_on_commit=False,
    )
    from contextlib import asynccontextmanager

    @asynccontextmanager
    async def _fake_maker():
        async with test_sm() as s:
            yield s

    async def _fake_embed(_):
        return vec

    with _EmbedPatch(_fake_embed), patch(
        "app.services.storage.upload_photo", side_effect=_upload_stub(),
    ), patch(
        "app.api.v1.photos.async_session_maker", _fake_maker,
    ):
        resp = await c.post(
            f"/pets/{pet_id}/photos",
            files=_upload_files(1),
            data=data,
            headers=headers,
        )
    assert resp.status_code == 200

    rows = await _fetch_embeddings(test_engine, pet_id)
    assert len(rows) == 1
    assert rows[0].source == EmbeddingSource.USER_UPLOADED


async def test_upload_rejects_invalid_classify_source(client):
    c, _ = client
    token = await _login(c, "13800150072")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    data = {"taken_at": ["2024-02-15"], "classify_source": ["bogus"]}

    with patch("app.services.storage.upload_photo", side_effect=_upload_stub()):
        resp = await c.post(
            f"/pets/{pet_id}/photos",
            files=_upload_files(1),
            data=data,
            headers=headers,
        )
    assert resp.status_code == 400
    assert resp.json()["code"] == "CLASSIFY_SOURCE_INVALID"


async def test_upload_rejects_mismatched_classify_source_count(client):
    c, _ = client
    token = await _login(c, "13800150073")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    # 2 files but only 1 classify_source → mismatch.
    data = {
        "taken_at": ["2024-02-15", "2024-02-16"],
        "classify_source": ["auto"],
    }

    with patch("app.services.storage.upload_photo", side_effect=_upload_stub()):
        resp = await c.post(
            f"/pets/{pet_id}/photos",
            files=_upload_files(2),
            data=data,
            headers=headers,
        )
    assert resp.status_code == 400
    assert resp.json()["code"] == "CLASSIFY_SOURCE_MISMATCH"


async def test_upload_embedding_failure_does_not_break_upload(client, test_engine):
    """DashScope outage during backfill must leave the upload 200-OK."""
    c, _ = client
    token = await _login(c, "13800150080")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    data = {"taken_at": ["2024-03-15"], "classify_source": ["auto"]}

    async def _boom(_):
        raise embedding_mod.EmbeddingUnavailableError("down")

    with _EmbedPatch(_boom), patch(
        "app.services.storage.upload_photo", side_effect=_upload_stub(),
    ):
        resp = await c.post(
            f"/pets/{pet_id}/photos",
            files=_upload_files(1),
            data=data,
            headers=headers,
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["success_count"] == 1
    # Backfill swallowed the error; no embedding row was created.
    rows = await _fetch_embeddings(test_engine, pet_id)
    assert rows == []
