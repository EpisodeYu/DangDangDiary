"""Step 2 auth module — automated tests.

Covers:
  1. send-code 200 + writes verify & limit keys
  2. send-code 400 for invalid phone
  3. send-code 429 for rate-limited phone
  4. login with correct code
  5. login with wrong / expired code → 400
  6. first login creates user record
  7. refresh with valid refresh token
  8. refresh with blacklisted token → 401
  9. logout blacklists refresh token
 10. GET /auth/me without token → 401
 11. PUT /auth/me updates nickname
"""
import pytest
from tests.conftest import _mock_sms_send

pytestmark = pytest.mark.asyncio


# ── helpers ──

async def _send_code(client, phone="13800138000", code="123456"):
    with _mock_sms_send(code):
        return await client.post("/auth/send-code", json={"phone": phone})


async def _login(client, phone="13800138000", code="123456"):
    await _send_code(client, phone, code)
    return await client.post("/auth/login", json={"phone": phone, "code": code})


# ── 1. send-code success ──

async def test_send_code_success(client):
    c, store = client
    resp = await _send_code(c)
    assert resp.status_code == 200
    body = resp.json()
    assert body["expire_seconds"] == 300
    assert "sms:verify:13800138000" in store
    assert "sms:limit:13800138000" in store


# ── 2. send-code invalid phone ──

async def test_send_code_invalid_phone(client):
    c, _ = client
    resp = await c.post("/auth/send-code", json={"phone": "123"})
    assert resp.status_code == 400
    assert resp.json()["code"] == "INVALID_PHONE"


# ── 3. send-code rate limited ──

async def test_send_code_rate_limited(client):
    c, _ = client
    await _send_code(c, phone="13900139000")
    with _mock_sms_send():
        resp = await c.post("/auth/send-code", json={"phone": "13900139000"})
    assert resp.status_code == 429
    assert resp.json()["code"] == "SMS_RATE_LIMITED"


# ── 4. login with correct code ──

async def test_login_success(client):
    c, _ = client
    resp = await _login(c, phone="13800138001")
    assert resp.status_code == 200
    body = resp.json()
    assert "access_token" in body
    assert "refresh_token" in body
    assert body["token_type"] == "bearer"
    assert body["user"]["phone"] == "13800138001"


# ── 5. login with wrong code ──

async def test_login_wrong_code(client):
    c, _ = client
    await _send_code(c, phone="13800138002", code="111111")
    resp = await c.post("/auth/login", json={"phone": "13800138002", "code": "999999"})
    assert resp.status_code == 400
    assert resp.json()["code"] == "INVALID_VERIFY_CODE"


# ── 6. first login creates user ──

async def test_first_login_creates_user(client):
    c, store = client
    phone = "13800138003"
    resp = await _login(c, phone=phone)
    assert resp.status_code == 200
    user = resp.json()["user"]
    assert user["phone"] == phone
    assert user["id"] is not None

    # clear rate limit so we can send-code again for the same phone
    store.pop(f"sms:limit:{phone}", None)

    # login again — same user, not a new one
    resp2 = await _login(c, phone=phone)
    assert resp2.json()["user"]["id"] == user["id"]


# ── 7. refresh with valid token ──

async def test_refresh_success(client):
    c, _ = client
    login_resp = await _login(c, phone="13800138004")
    refresh_token = login_resp.json()["refresh_token"]

    resp = await c.post("/auth/refresh", json={"refresh_token": refresh_token})
    assert resp.status_code == 200
    assert "access_token" in resp.json()
    assert resp.json()["token_type"] == "bearer"


# ── 8. refresh with blacklisted token ──

async def test_refresh_blacklisted(client):
    c, _ = client
    login_resp = await _login(c, phone="13800138005")
    tokens = login_resp.json()
    access_token = tokens["access_token"]
    refresh_token = tokens["refresh_token"]

    # logout to blacklist
    await c.post(
        "/auth/logout",
        json={"refresh_token": refresh_token},
        headers={"Authorization": f"Bearer {access_token}"},
    )

    resp = await c.post("/auth/refresh", json={"refresh_token": refresh_token})
    assert resp.status_code == 401
    assert resp.json()["code"] == "INVALID_REFRESH_TOKEN"


# ── 9. logout blacklists refresh token ──

async def test_logout_blacklists_token(client):
    c, store = client
    login_resp = await _login(c, phone="13800138006")
    tokens = login_resp.json()
    access_token = tokens["access_token"]
    refresh_token = tokens["refresh_token"]

    resp = await c.post(
        "/auth/logout",
        json={"refresh_token": refresh_token},
        headers={"Authorization": f"Bearer {access_token}"},
    )
    assert resp.status_code == 204
    assert f"auth:refresh:blacklist:{refresh_token}" in store


# ── 10. GET /auth/me without token ──

async def test_me_no_token(client):
    c, _ = client
    resp = await c.get("/auth/me")
    assert resp.status_code == 401
    assert resp.json()["code"] == "INVALID_ACCESS_TOKEN"


# ── 11. PUT /auth/me updates nickname ──

async def test_update_nickname(client):
    c, _ = client
    login_resp = await _login(c, phone="13800138007")
    access_token = login_resp.json()["access_token"]
    headers = {"Authorization": f"Bearer {access_token}"}

    resp = await c.put("/auth/me", json={"nickname": "当当妈妈"}, headers=headers)
    assert resp.status_code == 200
    assert resp.json()["nickname"] == "当当妈妈"

    # verify via GET
    me_resp = await c.get("/auth/me", headers=headers)
    assert me_resp.json()["nickname"] == "当当妈妈"


# ── extra: empty nickname rejected ──

async def test_update_nickname_empty(client):
    c, _ = client
    login_resp = await _login(c, phone="13800138008")
    headers = {"Authorization": f"Bearer {login_resp.json()['access_token']}"}

    resp = await c.put("/auth/me", json={"nickname": "   "}, headers=headers)
    assert resp.status_code == 400
    assert resp.json()["code"] == "INVALID_NICKNAME"
