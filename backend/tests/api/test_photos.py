"""Step 4 photo module — automated tests (Chunk A-5 / §2.2).

Covers:
  * Single / 3 / 5 file upload happy path (MinIO + recognition mocked)
  * 10 files → 400 TOO_MANY_FILES (cap bumped 5 → 9 in 2026-05-23
    batch-1 follow-up; this test now drives one over the new cap)
  * Oversize (> 15 MB) → per-file FILE_TOO_LARGE failure + mixed partial success
  * Unsupported content-type → per-file UNSUPPORTED_IMAGE_TYPE failure
  * ENABLE_SERVER_PET_RECOGNITION=True + recognize_pet says not a pet → PET_NOT_DETECTED failure
  * taken_at / files length mismatch → 400 TAKEN_AT_MISMATCH
  * DELETE /photos/{id} triggers storage.delete_photo_objects
  * GET /photos/{id}/url returns signed URL rooted at PUBLIC_BASE_URL

Idempotency-Key tests are deferred to Chunk D-5 per the step-8 doc.
"""
from datetime import date, datetime
from unittest.mock import patch

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, AsyncSession

import app.models  # noqa: F401  ensure ORM models registered
from app.config import settings
from app.models.photo import Photo

from tests.conftest import _mock_sms_send

pytestmark = pytest.mark.asyncio


# ---------------- Helpers ----------------

async def _login(c, phone: str, code: str = "123456"):
    with _mock_sms_send(code):
        await c.post("/auth/send-code", json={"phone": phone})
    resp = await c.post("/auth/login", json={"phone": phone, "code": code})
    return resp.json()["access_token"]


async def _create_pet(c, headers, *, name="橘子", pet_type="cat"):
    resp = await c.post("/pets", json={"name": name, "pet_type": pet_type}, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


def _jpeg_stub(size: int = 256) -> bytes:
    # Valid JPEG magic header is enough — storage.upload_photo is mocked.
    return b"\xff\xd8\xff\xe0" + b"\x00" * max(0, size - 4)


def _upload_photo_stub(index_counter: list[int]):
    """Return a deterministic (storage_key, thumbnail_key, thumbnail_sm_key) per call."""
    def _inner(pet_id: int, file_data: bytes, content_type: str):
        i = index_counter[0]
        index_counter[0] += 1
        return (
            f"{pet_id}/stub_{i}.jpg",
            f"{pet_id}/stub_{i}_thumb.jpg",
            f"{pet_id}/stub_{i}_thumb_sm.jpg",
        )
    return _inner


def _build_files_payload(n: int, *, content_type: str = "image/jpeg", size: int = 256):
    return [
        ("files", (f"p{i}.jpg", _jpeg_stub(size), content_type))
        for i in range(n)
    ]


# ---------------- Happy path: 1 / 3 / 5 ----------------

@pytest.mark.parametrize("count", [1, 3, 5])
async def test_upload_photos_success(client, count):
    c, _ = client
    token = await _login(c, f"138001400{count:02d}")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    files = _build_files_payload(count)
    data = {"taken_at": ["2024-01-15"] * count}

    counter = [0]
    # The route now calls `aupload_photo`, which offloads to a worker
    # thread via `asyncio.to_thread(upload_photo, ...)`. Patching the
    # underlying sync helper keeps these tests MinIO-free.
    with patch("app.services.storage.upload_photo", side_effect=_upload_photo_stub(counter)):
        resp = await c.post(
            f"/pets/{pet_id}/photos", files=files, data=data, headers=headers,
        )

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["total_count"] == count
    assert body["success_count"] == count
    assert body["failure_count"] == 0
    assert len(body["successes"]) == count
    assert body["successes"][0]["photo"]["pet_id"] == pet_id
    assert body["successes"][0]["photo"]["thumbnail_url"].startswith(
        settings.PUBLIC_BASE_URL
    )
    # New tier: small thumbnail URL is populated for every fresh upload and
    # is distinct from the large one (so the client can prefer it in grids).
    sm = body["successes"][0]["photo"]["thumbnail_sm_url"]
    assert sm.startswith(settings.PUBLIC_BASE_URL)
    assert sm.endswith("_thumb_sm.jpg")


# ---------------- Too many files ----------------

async def test_upload_too_many_files(client):
    c, _ = client
    token = await _login(c, "13800140020")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    # MAX_FILES_PER_UPLOAD = 9 (bumped from 5 in the 2026-05-23 batch-1
    # follow-up so a 3×3 photo grid can be submitted in one go). Drive
    # the test to MAX+1 = 10 to keep the assertion on the over-cap
    # branch rather than the new happy-path band.
    files = _build_files_payload(10)
    data = {"taken_at": ["2024-01-15"] * 10}

    resp = await c.post(
        f"/pets/{pet_id}/photos", files=files, data=data, headers=headers,
    )
    assert resp.status_code == 400
    assert resp.json()["code"] == "TOO_MANY_FILES"


# ---------------- Oversize / partial failure ----------------

async def test_upload_oversize_file_is_per_file_failure(client):
    c, _ = client
    token = await _login(c, "13800140021")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    big = _jpeg_stub(15 * 1024 * 1024 + 10)
    files = [("files", ("huge.jpg", big, "image/jpeg"))]
    data = {"taken_at": ["2024-01-15"]}

    counter = [0]
    with patch("app.services.storage.upload_photo", side_effect=_upload_photo_stub(counter)):
        resp = await c.post(
            f"/pets/{pet_id}/photos", files=files, data=data, headers=headers,
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["success_count"] == 0
    assert body["failure_count"] == 1
    assert body["failures"][0]["code"] == "FILE_TOO_LARGE"


async def test_upload_mixed_partial_success(client):
    """One legal + one oversize + one bad-type → only the legal one lands."""
    c, _ = client
    token = await _login(c, "13800140022")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    files = [
        ("files", ("ok.jpg", _jpeg_stub(256), "image/jpeg")),
        ("files", ("huge.jpg", _jpeg_stub(15 * 1024 * 1024 + 10), "image/jpeg")),
        ("files", ("bad.gif", b"GIF89a" + b"\x00" * 100, "image/gif")),
    ]
    data = {"taken_at": ["2024-01-15"] * 3}

    counter = [0]
    with patch("app.services.storage.upload_photo", side_effect=_upload_photo_stub(counter)):
        resp = await c.post(
            f"/pets/{pet_id}/photos", files=files, data=data, headers=headers,
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["total_count"] == 3
    assert body["success_count"] == 1
    assert body["failure_count"] == 2

    codes = {f["code"] for f in body["failures"]}
    assert codes == {"FILE_TOO_LARGE", "UNSUPPORTED_IMAGE_TYPE"}


# ---------------- Bad content-type ----------------

async def test_upload_unsupported_content_type(client):
    c, _ = client
    token = await _login(c, "13800140023")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    files = [("files", ("bad.gif", b"GIF89a" + b"\x00" * 100, "image/gif"))]
    data = {"taken_at": ["2024-01-15"]}

    resp = await c.post(
        f"/pets/{pet_id}/photos", files=files, data=data, headers=headers,
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["success_count"] == 0
    assert body["failures"][0]["code"] == "UNSUPPORTED_IMAGE_TYPE"


# ---------------- taken_at mismatch ----------------

async def test_upload_taken_at_count_mismatch(client):
    c, _ = client
    token = await _login(c, "13800140024")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    files = _build_files_payload(2)
    data = {"taken_at": ["2024-01-15"]}  # only 1 date for 2 files

    resp = await c.post(
        f"/pets/{pet_id}/photos", files=files, data=data, headers=headers,
    )
    assert resp.status_code == 400
    assert resp.json()["code"] == "TAKEN_AT_MISMATCH"


# ---------------- Server-side recognition gate ----------------

async def test_upload_pet_not_detected_when_recognition_enabled(client, monkeypatch):
    c, _ = client
    token = await _login(c, "13800140025")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    monkeypatch.setattr(settings, "ENABLE_SERVER_PET_RECOGNITION", True)

    files = _build_files_payload(1)
    data = {"taken_at": ["2024-01-15"]}

    def _not_a_pet(_file_data: bytes):
        return {"is_pet": False, "labels": ["sofa", "table"]}

    counter = [0]
    with patch("app.api.v1.photos.recognize_pet", side_effect=_not_a_pet), \
            patch("app.services.storage.upload_photo",
                  side_effect=_upload_photo_stub(counter)) as upload_mock:
        resp = await c.post(
            f"/pets/{pet_id}/photos", files=files, data=data, headers=headers,
        )

    assert resp.status_code == 200
    body = resp.json()
    assert body["success_count"] == 0
    assert body["failures"][0]["code"] == "PET_NOT_DETECTED"
    # Upload must short-circuit before storage.
    assert upload_mock.call_count == 0


# ---------------- Delete triggers MinIO cleanup ----------------

async def test_delete_photo_triggers_minio_cleanup(client, test_engine):
    c, _ = client
    token = await _login(c, "13800140026")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    # Seed a photo row via DB.
    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        p = Photo(
            pet_id=pet_id,
            user_id=1,  # belongs to the owner user; not checked in delete path
            storage_key=f"{pet_id}/to_delete.jpg",
            thumbnail_key=f"{pet_id}/to_delete_thumb.jpg",
            taken_at=date(2024, 1, 1),
            created_at=datetime(2024, 1, 1, 0, 0, 0),
        )
        s.add(p)
        await s.commit()
        await s.refresh(p)
        photo_id = p.id

    # `adelete_photo_objects` delegates to `storage.delete_photo_objects`
    # via `asyncio.to_thread`, so patching the sync helper captures the
    # call and keeps the test MinIO-free.
    with patch("app.services.storage.delete_photo_objects") as del_mock:
        resp = await c.delete(f"/photos/{photo_id}", headers=headers)

    assert resp.status_code == 204
    assert del_mock.call_count == 1
    # The route now passes (storage_key, thumbnail_key, thumbnail_sm_key).
    args = del_mock.call_args.args
    assert args[0] == f"{pet_id}/to_delete.jpg"
    assert args[1] == f"{pet_id}/to_delete_thumb.jpg"
    # Legacy seeded row above has no `thumbnail_sm_key`, so the third arg
    # should arrive as None and storage skips deletion of the missing tier.
    assert len(args) == 3 and args[2] is None

    async with sm() as s:
        remaining = (
            await s.execute(select(Photo).where(Photo.id == photo_id))
        ).scalar_one_or_none()
        assert remaining is None


async def test_delete_photo_not_found(client):
    c, _ = client
    token = await _login(c, "13800140027")
    headers = {"Authorization": f"Bearer {token}"}

    resp = await c.delete("/photos/999999", headers=headers)
    assert resp.status_code == 404
    assert resp.json()["code"] == "PHOTO_NOT_FOUND"


# ---------------- Signed URL ----------------

async def test_get_photo_presigned_url(client, test_engine):
    c, _ = client
    token = await _login(c, "13800140028")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        p = Photo(
            pet_id=pet_id,
            user_id=1,
            storage_key=f"{pet_id}/signed.jpg",
            thumbnail_key=f"{pet_id}/signed_thumb.jpg",
            taken_at=date(2024, 3, 1),
            created_at=datetime(2024, 3, 1, 0, 0, 0),
        )
        s.add(p)
        await s.commit()
        await s.refresh(p)
        photo_id = p.id

    signed = (
        f"{settings.PUBLIC_BASE_URL}/media/{settings.MINIO_BUCKET_PHOTOS}"
        f"/{pet_id}/signed.jpg?X-Amz-Signature=abc"
    )
    with patch("app.api.v1.photos.get_photo_presigned_url", return_value=signed) as mock:
        resp = await c.get(f"/photos/{photo_id}/url", headers=headers)

    assert resp.status_code == 200
    body = resp.json()
    assert body["url"] == signed
    assert body["url"].startswith(settings.PUBLIC_BASE_URL)
    assert body["expires_in"] == 3600
    assert mock.call_args.args[0] == f"{pet_id}/signed.jpg"
