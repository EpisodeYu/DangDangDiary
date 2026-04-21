"""Phase 2 Step 2 — voice intake API tests.

Mocks STT / LLM / MinIO at the voice_intake_service boundary so the
full intake → confirm → cancel flow is exercised without any
third-party dependencies.
"""
from datetime import date, timedelta
from unittest.mock import AsyncMock, patch

import pytest

import app.models  # noqa: F401  ensure all ORM models are registered
from app.services import voice_intake as voice_intake_service
from app.services import storage as storage_mod

from tests.conftest import _mock_sms_send

pytestmark = pytest.mark.asyncio


# ---------------- Helpers ----------------

async def _login(c, phone: str, code: str = "123456"):
    with _mock_sms_send(code):
        await c.post("/auth/send-code", json={"phone": phone})
    resp = await c.post("/auth/login", json={"phone": phone, "code": code})
    return resp.json()["access_token"]


async def _create_pet(c, headers, *, name="咪咪", pet_type="cat"):
    resp = await c.post(
        "/pets",
        json={"name": name, "pet_type": pet_type},
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


def _audio_stub() -> bytes:
    # 1KB of junk — MinIO upload is mocked, STT never touches it.
    return b"\x00" * 1024


def _multipart(client_request_id: str, *, default_pet_id: int | None = None):
    data = {"client_request_id": client_request_id}
    if default_pet_id is not None:
        data["default_pet_id"] = str(default_pet_id)
    files = {"audio_file": ("clip.m4a", _audio_stub(), "audio/m4a")}
    return data, files


def _patch_upstream(
    transcript: str | Exception,
    llm_output: dict | Exception,
):
    """Patch STT / LLM / MinIO upload in one context."""

    async def _stt(*args, **kwargs):
        if isinstance(transcript, Exception):
            raise transcript
        return transcript

    async def _llm(*args, **kwargs):
        if isinstance(llm_output, Exception):
            raise llm_output
        out = dict(llm_output)
        out.setdefault("_raw", "{}")
        return out

    async def _upload(user_id, data, mime, *, request_id):
        return f"{user_id}/test/{request_id}.m4a"

    def _presign(object_key, expires_seconds=900):
        return f"http://test/media/voice-intake/{object_key}?sig=stub"

    async def _delete(_):
        return None

    return [
        patch.object(voice_intake_service, "stt_transcribe", side_effect=_stt),
        patch.object(voice_intake_service, "llm_extract_intent", side_effect=_llm),
        patch.object(storage_mod, "aupload_voice_audio", side_effect=_upload),
        patch.object(storage_mod, "voice_audio_presigned_url", side_effect=_presign),
        patch.object(storage_mod, "adelete_voice_audio", side_effect=_delete),
    ]


# ---------------- intake: happy path, draft_pending ----------------


async def test_intake_deworming_draft_pending(client):
    c, _ = client
    token = await _login(c, "13800139201")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers, name="咪咪")

    data, files = _multipart("req-1", default_pet_id=pet_id)

    patches = _patch_upstream(
        transcript="今天给咪咪做了驱虫",
        llm_output={
            "intent": "deworming",
            "pet_name": "咪咪",
            "dewormed_at": "today",
            "deworming_type": "internal",
            "confidence": 88,
        },
    )
    for p in patches:
        p.start()
    try:
        resp = await c.post(
            "/voice/intake", data=data, files=files, headers=headers,
        )
    finally:
        for p in patches:
            p.stop()

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "draft_pending"
    assert body["intent"] == "deworming"
    assert body["confidence"] == 88
    assert body["transcript"] == "今天给咪咪做了驱虫"
    assert body["missing_fields"] == []
    assert body["needs_confirm"] is False
    draft = body["draft"]
    assert draft["pet_id"] == pet_id
    assert draft["deworming_type"] == "internal"
    assert draft["dewormed_at"] == date.today().isoformat()


# ---------------- intake: STT fails ----------------


async def test_intake_stt_failed(client):
    from app.services.stt import SttUnavailableError

    c, _ = client
    token = await _login(c, "13800139202")
    headers = {"Authorization": f"Bearer {token}"}
    await _create_pet(c, headers)

    data, files = _multipart("req-stt-fail")
    patches = _patch_upstream(
        transcript=SttUnavailableError("empty"),
        llm_output={"intent": "unknown"},
    )
    for p in patches:
        p.start()
    try:
        resp = await c.post(
            "/voice/intake", data=data, files=files, headers=headers,
        )
    finally:
        for p in patches:
            p.stop()

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "stt_failed"
    assert body["transcript"] is None
    assert body["intent"] is None
    assert body["draft"] is None


# ---------------- intake: LLM says unknown ----------------


async def test_intake_intent_unknown(client):
    c, _ = client
    token = await _login(c, "13800139203")
    headers = {"Authorization": f"Bearer {token}"}
    await _create_pet(c, headers)

    data, files = _multipart("req-unknown")
    patches = _patch_upstream(
        transcript="今天天气不错",
        llm_output={"intent": "unknown", "confidence": 30},
    )
    for p in patches:
        p.start()
    try:
        resp = await c.post(
            "/voice/intake", data=data, files=files, headers=headers,
        )
    finally:
        for p in patches:
            p.stop()

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["status"] == "intent_unknown"
    assert body["transcript"] == "今天天气不错"
    assert body["intent"] == "unknown"
    assert body["draft"] is None


# ---------------- intake: missing fields ----------------


async def test_intake_missing_fields_triggers_confirm(client):
    c, _ = client
    token = await _login(c, "13800139204")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers, name="咪咪")

    data, files = _multipart("req-missing", default_pet_id=pet_id)
    patches = _patch_upstream(
        transcript="今天给咪咪做了驱虫",
        llm_output={
            "intent": "deworming",
            "pet_name": "咪咪",
            "dewormed_at": "today",
            # deworming_type is missing — should land in missing_fields.
            "deworming_type": None,
            "confidence": 90,
        },
    )
    for p in patches:
        p.start()
    try:
        resp = await c.post(
            "/voice/intake", data=data, files=files, headers=headers,
        )
    finally:
        for p in patches:
            p.stop()

    assert resp.status_code == 200
    body = resp.json()
    assert body["status"] == "draft_pending"
    assert body["missing_fields"] == ["deworming_type"]
    assert body["needs_confirm"] is True


# ---------------- intake: client_request_id dedup ----------------


async def test_intake_dedup_by_client_request_id(client):
    c, store = client
    token = await _login(c, "13800139205")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers, name="咪咪")

    # Our conftest Redis mock doesn't implement setex/get for non-SMS
    # keys; patch just the two Redis helpers we need.
    async def _redis_get(key):
        return store.get(key)

    async def _redis_setex(key, ttl, value):
        store[key] = value

    class _FakeRedis:
        async def get(self, key):
            return store.get(key)

        async def setex(self, key, ttl, value):
            store[key] = value

    from app.services import redis as redis_mod

    with patch.object(redis_mod, "get_redis", return_value=_FakeRedis()):
        data, files = _multipart("dedup-key-1", default_pet_id=pet_id)
        patches = _patch_upstream(
            transcript="今天给咪咪做了驱虫",
            llm_output={
                "intent": "deworming",
                "pet_name": "咪咪",
                "dewormed_at": "today",
                "deworming_type": "internal",
                "confidence": 85,
            },
        )
        for p in patches:
            p.start()
        try:
            resp1 = await c.post(
                "/voice/intake", data=data, files=files, headers=headers,
            )
            assert resp1.status_code == 200
            rid_1 = resp1.json()["request_id"]

            # Second call with same client_request_id returns the cached
            # response (same request_id, no new log written).
            data2, files2 = _multipart("dedup-key-1", default_pet_id=pet_id)
            resp2 = await c.post(
                "/voice/intake", data=data2, files=files2, headers=headers,
            )
            assert resp2.status_code == 200
            assert resp2.json()["request_id"] == rid_1
        finally:
            for p in patches:
                p.stop()


# ---------------- intake: invalid mime / too big ----------------


async def test_intake_rejects_non_audio(client):
    c, _ = client
    token = await _login(c, "13800139206")
    headers = {"Authorization": f"Bearer {token}"}
    await _create_pet(c, headers)

    files = {"audio_file": ("not.jpg", b"\xff\xd8" + b"\x00" * 64, "image/jpeg")}
    data = {"client_request_id": "req-bad-mime"}

    # Upstream is still patched so we don't accidentally hit the network
    # if the API mistakenly accepts the upload.
    patches = _patch_upstream(transcript="x", llm_output={"intent": "unknown"})
    for p in patches:
        p.start()
    try:
        resp = await c.post(
            "/voice/intake", data=data, files=files, headers=headers,
        )
    finally:
        for p in patches:
            p.stop()

    assert resp.status_code == 400
    assert resp.json()["code"] == "voice_audio_invalid"


# ---------------- confirm: dispatch + idempotency ----------------


async def test_confirm_creates_deworming(client):
    c, _ = client
    token = await _login(c, "13800139207")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers, name="咪咪")

    # Step 1: intake draft_pending
    data, files = _multipart("req-confirm-1", default_pet_id=pet_id)
    patches = _patch_upstream(
        transcript="今天给咪咪做了驱虫",
        llm_output={
            "intent": "deworming",
            "pet_name": "咪咪",
            "dewormed_at": "today",
            "deworming_type": "internal",
            "confidence": 90,
        },
    )
    for p in patches:
        p.start()
    try:
        resp = await c.post(
            "/voice/intake", data=data, files=files, headers=headers,
        )
    finally:
        for p in patches:
            p.stop()
    assert resp.status_code == 200
    body = resp.json()
    request_id = body["request_id"]
    draft = body["draft"]

    # Step 2: confirm
    confirm_body = {
        "request_id": request_id,
        "intent": "deworming",
        "payload": {
            "pet_id": draft["pet_id"],
            "deworming_type": draft["deworming_type"],
            "dewormed_at": draft["dewormed_at"],
        },
    }
    resp2 = await c.post(
        "/voice/intake/confirm", json=confirm_body, headers=headers,
    )
    assert resp2.status_code == 200, resp2.text
    body2 = resp2.json()
    assert body2["status"] == "confirmed"
    assert body2["entity_type"] == "deworming"
    assert body2["entity"]["deworming_type"] == "internal"

    # Step 3: second confirm → 409 invalid_state
    resp3 = await c.post(
        "/voice/intake/confirm", json=confirm_body, headers=headers,
    )
    assert resp3.status_code == 409
    assert resp3.json()["code"] == "voice_intake_invalid_state"


async def test_confirm_rejects_other_users_draft(client):
    c, _ = client
    token_a = await _login(c, "13800139208")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet_id = await _create_pet(c, headers_a, name="咪咪")

    data, files = _multipart("req-confirm-cross", default_pet_id=pet_id)
    patches = _patch_upstream(
        transcript="今天给咪咪做了驱虫",
        llm_output={
            "intent": "deworming",
            "pet_name": "咪咪",
            "dewormed_at": "today",
            "deworming_type": "internal",
            "confidence": 90,
        },
    )
    for p in patches:
        p.start()
    try:
        resp = await c.post(
            "/voice/intake", data=data, files=files, headers=headers_a,
        )
    finally:
        for p in patches:
            p.stop()
    request_id = resp.json()["request_id"]
    draft = resp.json()["draft"]

    token_b = await _login(c, "13800139209")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    resp_b = await c.post(
        "/voice/intake/confirm",
        json={
            "request_id": request_id,
            "intent": "deworming",
            "payload": {
                "pet_id": draft["pet_id"],
                "deworming_type": "internal",
                "dewormed_at": draft["dewormed_at"],
            },
        },
        headers=headers_b,
    )
    assert resp_b.status_code == 404
    assert resp_b.json()["code"] == "voice_intake_not_found"


# ---------------- cancel ----------------


async def test_cancel_draft(client):
    c, _ = client
    token = await _login(c, "13800139210")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers, name="咪咪")

    data, files = _multipart("req-cancel-1", default_pet_id=pet_id)
    patches = _patch_upstream(
        transcript="今天给咪咪做了驱虫",
        llm_output={
            "intent": "deworming",
            "pet_name": "咪咪",
            "dewormed_at": "today",
            "deworming_type": "internal",
            "confidence": 85,
        },
    )
    for p in patches:
        p.start()
    try:
        resp = await c.post(
            "/voice/intake", data=data, files=files, headers=headers,
        )
        request_id = resp.json()["request_id"]

        resp2 = await c.delete(
            f"/voice/intake/{request_id}", headers=headers,
        )
        assert resp2.status_code == 204

        # Confirming a canceled draft fails with invalid_state
        resp3 = await c.post(
            "/voice/intake/confirm",
            json={
                "request_id": request_id,
                "intent": "deworming",
                "payload": {
                    "pet_id": pet_id,
                    "deworming_type": "internal",
                    "dewormed_at": date.today().isoformat(),
                },
            },
            headers=headers,
        )
        assert resp3.status_code == 409
    finally:
        for p in patches:
            p.stop()
