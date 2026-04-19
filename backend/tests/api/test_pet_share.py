"""Phase 2 step 1 — pet share code & member management API tests."""
from datetime import timedelta

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, AsyncSession

import app.models  # noqa: F401  ensure all ORM models are registered
from app.models.pet import MemberRole, PetMember, PetShareCode
from app.utils.time import utcnow

from tests.conftest import _mock_sms_send

pytestmark = pytest.mark.asyncio


# ---------------- Helpers ----------------

async def _login(c, phone: str, code: str = "123456"):
    with _mock_sms_send(code):
        await c.post("/auth/send-code", json={"phone": phone})
    resp = await c.post("/auth/login", json={"phone": phone, "code": code})
    body = resp.json()
    return body["access_token"], body["user"]["id"]


async def _create_pet(c, headers, *, name="橘子", pet_type="cat"):
    resp = await c.post(
        "/pets", json={"name": name, "pet_type": pet_type}, headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()


async def _generate_code(c, headers, pet_id: int) -> str:
    resp = await c.post(f"/pets/{pet_id}/share-code", headers=headers)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert len(body["code"]) == 8
    return body["code"]


# ---------------- Generate / get / revoke ----------------

async def test_owner_generate_get_revoke_share_code(client):
    c, _ = client
    token, _ = await _login(c, "13900100001")
    headers = {"Authorization": f"Bearer {token}"}
    pet = await _create_pet(c, headers)
    pet_id = pet["id"]

    # No active code yet → 204.
    resp = await c.get(f"/pets/{pet_id}/share-code", headers=headers)
    assert resp.status_code == 204

    code = await _generate_code(c, headers, pet_id)

    # Now GET returns the active one.
    resp = await c.get(f"/pets/{pet_id}/share-code", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["code"] == code

    # Pet detail flips share_code_active to true for owner.
    resp = await c.get(f"/pets/{pet_id}", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["share_code_active"] is True

    # Revoke.
    resp = await c.delete(f"/pets/{pet_id}/share-code", headers=headers)
    assert resp.status_code == 204

    resp = await c.get(f"/pets/{pet_id}/share-code", headers=headers)
    assert resp.status_code == 204

    resp = await c.get(f"/pets/{pet_id}", headers=headers)
    assert resp.json()["share_code_active"] is False


async def test_only_owner_can_manage_share_code(client, test_engine):
    c, _ = client
    token_a, _ = await _login(c, "13900100002")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a)
    pet_id = pet["id"]

    token_b, user_b_id = await _login(c, "13900100003")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        s.add(PetMember(pet_id=pet_id, user_id=user_b_id, role=MemberRole.EDITOR))
        await s.commit()

    for verb, fn in (
        ("POST", c.post), ("GET", c.get), ("DELETE", c.delete),
    ):
        resp = await fn(f"/pets/{pet_id}/share-code", headers=headers_b)
        assert resp.status_code == 403, (verb, resp.text)
        assert resp.json()["code"] == "PET_OWNER_REQUIRED"


async def test_regenerate_revokes_previous(client):
    c, _ = client
    token, _ = await _login(c, "13900100004")
    headers = {"Authorization": f"Bearer {token}"}
    pet = await _create_pet(c, headers)
    pet_id = pet["id"]

    first = await _generate_code(c, headers, pet_id)
    second = await _generate_code(c, headers, pet_id)
    assert first != second

    # Bystander tries to redeem the previous one → REVOKED.
    token_b, _ = await _login(c, "13900100005")
    headers_b = {"Authorization": f"Bearer {token_b}"}
    resp = await c.post(
        "/pets/redeem", json={"code": first}, headers=headers_b,
    )
    assert resp.status_code == 400
    assert resp.json()["code"] == "SHARE_CODE_REVOKED"


# ---------------- Redeem ----------------

async def test_redeem_success_creates_viewer(client):
    c, _ = client
    token_a, _ = await _login(c, "13900100010")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a, name="花花")
    pet_id = pet["id"]

    code = await _generate_code(c, headers_a, pet_id)

    token_b, _ = await _login(c, "13900100011")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    resp = await c.post(
        "/pets/redeem", json={"code": code}, headers=headers_b,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["id"] == pet_id
    assert body["my_role"] == "viewer"
    assert body["is_owner"] is False

    # B sees the pet in their list.
    resp = await c.get("/pets", headers=headers_b)
    pets = resp.json()["pets"]
    assert any(p["id"] == pet_id and p["my_role"] == "viewer" for p in pets)

    # Code can no longer be reused.
    token_c, _ = await _login(c, "13900100012")
    headers_c = {"Authorization": f"Bearer {token_c}"}
    resp = await c.post(
        "/pets/redeem", json={"code": code}, headers=headers_c,
    )
    assert resp.status_code == 400
    assert resp.json()["code"] == "SHARE_CODE_USED"


async def test_redeem_self_forbidden(client):
    c, _ = client
    token, _ = await _login(c, "13900100020")
    headers = {"Authorization": f"Bearer {token}"}
    pet = await _create_pet(c, headers)
    code = await _generate_code(c, headers, pet["id"])

    resp = await c.post(
        "/pets/redeem", json={"code": code}, headers=headers,
    )
    assert resp.status_code == 400
    assert resp.json()["code"] == "SHARE_CODE_SELF_REDEEM"


async def test_redeem_already_member(client, test_engine):
    c, _ = client
    token_a, _ = await _login(c, "13900100030")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a)
    pet_id = pet["id"]

    token_b, user_b_id = await _login(c, "13900100031")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        s.add(PetMember(pet_id=pet_id, user_id=user_b_id, role=MemberRole.EDITOR))
        await s.commit()

    code = await _generate_code(c, headers_a, pet_id)
    resp = await c.post(
        "/pets/redeem", json={"code": code}, headers=headers_b,
    )
    assert resp.status_code == 400
    assert resp.json()["code"] == "SHARE_ALREADY_MEMBER"


async def test_redeem_expired(client, test_engine):
    c, _ = client
    token_a, _ = await _login(c, "13900100040")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a)
    pet_id = pet["id"]

    code = await _generate_code(c, headers_a, pet_id)

    # Force expiry in the DB.
    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        record = (
            await s.execute(select(PetShareCode).where(PetShareCode.code == code))
        ).scalar_one()
        record.expires_at = utcnow() - timedelta(seconds=1)
        await s.commit()

    token_b, _ = await _login(c, "13900100041")
    headers_b = {"Authorization": f"Bearer {token_b}"}
    resp = await c.post(
        "/pets/redeem", json={"code": code}, headers=headers_b,
    )
    assert resp.status_code == 400
    assert resp.json()["code"] == "SHARE_CODE_EXPIRED"


async def test_redeem_unknown_code(client):
    c, _ = client
    token, _ = await _login(c, "13900100050")
    headers = {"Authorization": f"Bearer {token}"}
    resp = await c.post(
        "/pets/redeem", json={"code": "ZZZZ9999"}, headers=headers,
    )
    assert resp.status_code == 404
    assert resp.json()["code"] == "SHARE_CODE_NOT_FOUND"


async def test_redeem_invalid_format_rejected(client):
    c, _ = client
    token, _ = await _login(c, "13900100051")
    headers = {"Authorization": f"Bearer {token}"}
    # 6-char code is too short → schema validation rejects.
    resp = await c.post("/pets/redeem", json={"code": "ABC123"}, headers=headers)
    assert resp.status_code == 400


# ---------------- Member management ----------------

async def test_list_members_owner_only(client, test_engine):
    c, _ = client
    token_a, _ = await _login(c, "13900100060")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a)
    pet_id = pet["id"]

    token_b, user_b_id = await _login(c, "13900100061")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        s.add(PetMember(pet_id=pet_id, user_id=user_b_id, role=MemberRole.VIEWER))
        await s.commit()

    # Owner gets the list, owner row excluded.
    resp = await c.get(f"/pets/{pet_id}/members", headers=headers_a)
    assert resp.status_code == 200
    members = resp.json()["members"]
    assert len(members) == 1
    assert members[0]["user_id"] == user_b_id
    assert members[0]["role"] == "viewer"

    # Viewer cannot list.
    resp = await c.get(f"/pets/{pet_id}/members", headers=headers_b)
    assert resp.status_code == 403
    assert resp.json()["code"] == "PET_OWNER_REQUIRED"


async def test_update_member_role_editor_then_back(client, test_engine):
    c, _ = client
    token_a, _ = await _login(c, "13900100070")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a)
    pet_id = pet["id"]

    token_b, user_b_id = await _login(c, "13900100071")

    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        s.add(PetMember(pet_id=pet_id, user_id=user_b_id, role=MemberRole.VIEWER))
        await s.commit()

    resp = await c.patch(
        f"/pets/{pet_id}/members/{user_b_id}",
        json={"role": "editor"},
        headers=headers_a,
    )
    assert resp.status_code == 200, resp.text
    assert resp.json()["role"] == "editor"

    resp = await c.patch(
        f"/pets/{pet_id}/members/{user_b_id}",
        json={"role": "viewer"},
        headers=headers_a,
    )
    assert resp.status_code == 200
    assert resp.json()["role"] == "viewer"


async def test_update_role_to_owner_rejected(client, test_engine):
    c, _ = client
    token_a, _ = await _login(c, "13900100080")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a)
    pet_id = pet["id"]

    token_b, user_b_id = await _login(c, "13900100081")
    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        s.add(PetMember(pet_id=pet_id, user_id=user_b_id, role=MemberRole.VIEWER))
        await s.commit()

    resp = await c.patch(
        f"/pets/{pet_id}/members/{user_b_id}",
        json={"role": "owner"},
        headers=headers_a,
    )
    assert resp.status_code == 400


async def test_remove_member(client, test_engine):
    c, _ = client
    token_a, _ = await _login(c, "13900100090")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a)
    pet_id = pet["id"]

    token_b, user_b_id = await _login(c, "13900100091")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        s.add(PetMember(pet_id=pet_id, user_id=user_b_id, role=MemberRole.VIEWER))
        await s.commit()

    resp = await c.delete(
        f"/pets/{pet_id}/members/{user_b_id}", headers=headers_a,
    )
    assert resp.status_code == 204

    # B no longer sees the pet.
    resp = await c.get("/pets", headers=headers_b)
    assert resp.status_code == 200
    assert all(p["id"] != pet_id for p in resp.json()["pets"])


async def test_remove_self_rejected(client):
    c, _ = client
    token, user_id = await _login(c, "13900100092")
    headers = {"Authorization": f"Bearer {token}"}
    pet = await _create_pet(c, headers)

    resp = await c.delete(
        f"/pets/{pet['id']}/members/{user_id}", headers=headers,
    )
    assert resp.status_code == 400
    assert resp.json()["code"] == "SHARE_ROLE_INVALID"


async def test_update_member_not_found(client):
    c, _ = client
    token, _ = await _login(c, "13900100093")
    headers = {"Authorization": f"Bearer {token}"}
    pet = await _create_pet(c, headers)

    resp = await c.patch(
        f"/pets/{pet['id']}/members/9999",
        json={"role": "editor"},
        headers=headers,
    )
    assert resp.status_code == 404
    assert resp.json()["code"] == "SHARE_MEMBER_NOT_FOUND"
