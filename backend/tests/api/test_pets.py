"""Step 3 pet module — automated tests (Chunk A-4 / §2.2).

Covers:
  * CRUD (create → list → get → update → delete)
  * `invite_code` uniqueness across pets + owner-only visibility in responses
  * Owner vs member permissions (member can read, not update/delete/avatar)
  * Avatar upload: happy path / invalid content-type / > 5 MB
  * Delete cascade: associated rows wiped + MinIO prefix delete invoked
"""
from datetime import date, datetime
from unittest.mock import patch

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, AsyncSession

import app.models  # noqa: F401  ensure all ORM models are registered
from app.models.deworming import Deworming, DewormingType
from app.models.pet import MemberRole, Pet, PetMember
from app.models.photo import Photo
from app.models.routine import Routine, RoutineType
from app.models.user import User
from app.models.vaccination import Vaccination
from app.models.weight import Weight

from tests.conftest import _mock_sms_send

pytestmark = pytest.mark.asyncio


# ---------------- Helpers ----------------

async def _login(c, phone: str, code: str = "123456"):
    with _mock_sms_send(code):
        await c.post("/auth/send-code", json={"phone": phone})
    resp = await c.post("/auth/login", json={"phone": phone, "code": code})
    body = resp.json()
    return body["access_token"], body["user"]["id"]


async def _create_pet(c, headers, *, name="橘子", pet_type="cat", breed=None, birthday=None):
    payload: dict = {"name": name, "pet_type": pet_type}
    if breed is not None:
        payload["breed"] = breed
    if birthday is not None:
        payload["birthday"] = birthday
    resp = await c.post("/pets", json=payload, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()


async def _session(engine):
    return async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


# ---------------- CRUD + invite_code ----------------

async def test_pet_crud_roundtrip(client):
    c, _ = client
    token, _ = await _login(c, "13800139001")
    headers = {"Authorization": f"Bearer {token}"}

    created = await _create_pet(
        c, headers, name="橘子", pet_type="cat", breed="橘猫", birthday="2020-01-15",
    )
    pet_id = created["id"]
    assert created["is_owner"] is True
    assert created["my_role"] == "owner"
    assert created["invite_code"]  # owner sees invite_code
    assert created["name"] == "橘子"
    assert created["breed"] == "橘猫"
    assert created["birthday"] == "2020-01-15"

    # list — newest first, contains the pet
    resp = await c.get("/pets", headers=headers)
    assert resp.status_code == 200
    body = resp.json()
    assert body["total"] == 1
    assert body["pets"][0]["id"] == pet_id

    # get detail — owner sees invite_code
    resp = await c.get(f"/pets/{pet_id}", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["invite_code"] == created["invite_code"]

    # update
    resp = await c.put(
        f"/pets/{pet_id}",
        json={"name": "小橘", "breed": "中华田园猫"},
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["name"] == "小橘"
    assert resp.json()["breed"] == "中华田园猫"

    # delete
    resp = await c.delete(f"/pets/{pet_id}", headers=headers)
    assert resp.status_code == 204

    resp = await c.get(f"/pets/{pet_id}", headers=headers)
    assert resp.status_code == 404

    # list now empty
    resp = await c.get("/pets", headers=headers)
    assert resp.json()["total"] == 0


async def test_invite_code_unique_per_pet(client):
    c, _ = client
    token, _ = await _login(c, "13800139002")
    headers = {"Authorization": f"Bearer {token}"}

    a = await _create_pet(c, headers, name="橘子")
    b = await _create_pet(c, headers, name="花花")

    assert a["invite_code"]
    assert b["invite_code"]
    assert a["invite_code"] != b["invite_code"]


# ---------------- Owner vs member ----------------

async def test_member_can_read_but_not_write(client, test_engine):
    c, _ = client

    token_a, _ = await _login(c, "13800139003")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a, name="橘子")
    pet_id = pet["id"]

    token_b, user_b_id = await _login(c, "13800139004")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    # Manually enroll B as a MEMBER of A's pet.
    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        s.add(PetMember(pet_id=pet_id, user_id=user_b_id, role=MemberRole.MEMBER))
        await s.commit()

    # B can read detail — invite_code suppressed for non-owner.
    resp = await c.get(f"/pets/{pet_id}", headers=headers_b)
    assert resp.status_code == 200
    body = resp.json()
    assert body["is_owner"] is False
    assert body["my_role"] == "member"
    assert body["invite_code"] is None

    # B sees the pet in list.
    resp = await c.get("/pets", headers=headers_b)
    assert resp.status_code == 200
    assert any(p["id"] == pet_id for p in resp.json()["pets"])

    # B cannot update.
    resp = await c.put(f"/pets/{pet_id}", json={"name": "x"}, headers=headers_b)
    assert resp.status_code == 403
    assert resp.json()["code"] == "PET_OWNER_REQUIRED"

    # B cannot delete.
    resp = await c.delete(f"/pets/{pet_id}", headers=headers_b)
    assert resp.status_code == 403
    assert resp.json()["code"] == "PET_OWNER_REQUIRED"

    # B cannot upload avatar.
    files = {"file": ("x.jpg", b"\xff\xd8\xff" + b"\x00" * 100, "image/jpeg")}
    resp = await c.post(f"/pets/{pet_id}/avatar", files=files, headers=headers_b)
    assert resp.status_code == 403
    assert resp.json()["code"] == "PET_OWNER_REQUIRED"


async def test_pet_access_forbidden_for_unrelated_user(client):
    c, _ = client
    token_a, _ = await _login(c, "13800139005")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet = await _create_pet(c, headers_a)

    token_b, _ = await _login(c, "13800139006")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    resp = await c.get(f"/pets/{pet['id']}", headers=headers_b)
    assert resp.status_code == 403
    assert resp.json()["code"] == "PET_FORBIDDEN"


# ---------------- Avatar upload ----------------

async def test_avatar_upload_success(client):
    c, _ = client
    token, _ = await _login(c, "13800139007")
    headers = {"Authorization": f"Bearer {token}"}
    pet = await _create_pet(c, headers)
    pet_id = pet["id"]

    fake_url = "http://public.example.com/media/avatars/pets/1/123.jpg"

    files = {"file": ("avatar.jpg", b"\xff\xd8\xff" + b"\x00" * 256, "image/jpeg")}

    # The pet service now calls `aupload_pet_avatar`, which delegates
    # to `storage.upload_pet_avatar` via `asyncio.to_thread`. Patching
    # the sync helper keeps the assertion style unchanged.
    with patch(
        "app.services.storage.upload_pet_avatar", return_value=fake_url
    ) as upload_mock:
        resp = await c.post(f"/pets/{pet_id}/avatar", files=files, headers=headers)

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["avatar_url"] == fake_url
    assert upload_mock.call_count == 1
    args, _ = upload_mock.call_args
    assert args[0] == pet_id
    assert args[2] == "image/jpeg"


async def test_avatar_upload_invalid_content_type(client):
    c, _ = client
    token, _ = await _login(c, "13800139008")
    headers = {"Authorization": f"Bearer {token}"}
    pet = await _create_pet(c, headers)

    files = {"file": ("bad.gif", b"GIF89a" + b"\x00" * 10, "image/gif")}
    resp = await c.post(f"/pets/{pet['id']}/avatar", files=files, headers=headers)
    assert resp.status_code == 400
    assert resp.json()["code"] == "PET_AVATAR_INVALID"


async def test_avatar_upload_too_large(client):
    c, _ = client
    token, _ = await _login(c, "13800139009")
    headers = {"Authorization": f"Bearer {token}"}
    pet = await _create_pet(c, headers)

    big = b"\xff\xd8\xff" + b"\x00" * (5 * 1024 * 1024 + 1)
    files = {"file": ("huge.jpg", big, "image/jpeg")}

    resp = await c.post(f"/pets/{pet['id']}/avatar", files=files, headers=headers)
    assert resp.status_code == 400
    assert resp.json()["code"] == "PET_AVATAR_TOO_LARGE"


# ---------------- Delete cascade ----------------

async def test_delete_pet_cascades_all_tables_and_minio(client, test_engine):
    c, _ = client
    token, user_id = await _login(c, "13800139010")
    headers = {"Authorization": f"Bearer {token}"}
    pet = await _create_pet(c, headers, name="要删的")
    pet_id = pet["id"]

    # Set an avatar_url so the delete path triggers delete_object_by_url too.
    sm = async_sessionmaker(test_engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        pet_row = (await s.execute(select(Pet).where(Pet.id == pet_id))).scalar_one()
        pet_row.avatar_url = "http://public.example.com/media/avatars/pets/1/old.jpg"

        # Seed one record per child table so we can verify cascade.
        s.add(Photo(
            pet_id=pet_id, user_id=user_id,
            storage_key=f"{pet_id}/fake.jpg",
            thumbnail_key=f"{pet_id}/fake_thumb.jpg",
            taken_at=date(2024, 1, 1),
            created_at=datetime(2024, 1, 1, 0, 0, 0),
        ))
        s.add(Weight(
            pet_id=pet_id, user_id=user_id,
            weight_kg="4.5", recorded_at=date(2024, 1, 2),
            created_at=datetime(2024, 1, 2, 0, 0, 0),
        ))
        s.add(Deworming(
            pet_id=pet_id, user_id=user_id,
            deworming_type=DewormingType.INTERNAL,
            dewormed_at=date(2024, 1, 3),
            created_at=datetime(2024, 1, 3, 0, 0, 0),
        ))
        s.add(Vaccination(
            pet_id=pet_id, user_id=user_id,
            vaccine_type="猫三联疫苗", vaccinated_at=date(2024, 1, 4),
            created_at=datetime(2024, 1, 4, 0, 0, 0),
        ))
        s.add(Routine(
            pet_id=pet_id, user_id=user_id,
            routine_type=RoutineType.BATH,
            performed_at=date(2024, 1, 5),
            created_at=datetime(2024, 1, 5, 0, 0, 0),
        ))
        await s.commit()

    # Patch MinIO side-effects on the underlying sync helpers — the
    # service now calls the async wrappers, which dispatch through
    # `asyncio.to_thread(delete_object_by_url, ...)` etc.
    with patch("app.services.storage.delete_object_by_url") as del_url, \
            patch("app.services.storage.delete_objects_by_prefix") as del_prefix:
        resp = await c.delete(f"/pets/{pet_id}", headers=headers)

    assert resp.status_code == 204

    # Verify every child table is empty and the pet is gone.
    async with sm() as s:
        for model in (Photo, Weight, Deworming, Vaccination, Routine, PetMember):
            rows = (
                await s.execute(select(model).where(model.pet_id == pet_id))
            ).scalars().all()
            assert rows == [], f"{model.__name__} should be empty after pet delete"

        pet_row = (
            await s.execute(select(Pet).where(Pet.id == pet_id))
        ).scalar_one_or_none()
        assert pet_row is None

    # MinIO cleanup calls.
    assert del_url.call_count == 1
    assert del_url.call_args.args[0].endswith("/old.jpg")

    prefixes = [call.args for call in del_prefix.call_args_list]
    assert len(prefixes) == 3
    assert any(args[1] == f"{pet_id}/" for args in prefixes)
    assert any(args[1] == f"pets/{pet_id}/" for args in prefixes)
