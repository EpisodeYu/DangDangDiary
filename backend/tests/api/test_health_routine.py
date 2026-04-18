"""Step 5 health module — Routine tests (new in Chunk A-2).

Covers Routine CRUD (bath / nail_trim / grooming) + cycle config + status
calculation (enabled & disabled variants) + cross-user permission.
"""
import pytest
from datetime import date, timedelta

import app.models  # noqa: F401  register ORM models

from tests.conftest import _mock_sms_send

pytestmark = pytest.mark.asyncio


async def _login(c, phone: str, code: str = "123456"):
    with _mock_sms_send(code):
        await c.post("/auth/send-code", json={"phone": phone})
    resp = await c.post("/auth/login", json={"phone": phone, "code": code})
    return resp.json()["access_token"]


async def _create_pet(c, headers, name="橘子", pet_type="cat"):
    resp = await c.post("/pets", json={"name": name, "pet_type": pet_type}, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def test_routine_crud_all_types(client):
    c, _ = client
    token = await _login(c, phone="13800138120")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    today = date.today()
    created_ids = []

    for routine_type, offset_days in (("bath", 3), ("nail_trim", 10), ("grooming", 20)):
        resp = await c.post(
            f"/pets/{pet_id}/routines",
            json={
                "routine_type": routine_type,
                "performed_at": (today - timedelta(days=offset_days)).isoformat(),
            },
            headers=headers,
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["routine_type"] == routine_type
        assert body["pet_id"] == pet_id
        created_ids.append(body["id"])

    # list
    resp = await c.get(f"/pets/{pet_id}/routines", headers=headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 3
    # newest first (bath 3 days ago is newest)
    assert data["routines"][0]["routine_type"] == "bath"

    # update one record (change type + date)
    bath_id = created_ids[0]
    new_date = (today - timedelta(days=1)).isoformat()
    resp = await c.put(
        f"/routines/{bath_id}",
        json={"routine_type": "bath", "performed_at": new_date},
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["performed_at"] == new_date

    # delete
    for rid in created_ids:
        resp = await c.delete(f"/routines/{rid}", headers=headers)
        assert resp.status_code == 204

    resp = await c.get(f"/pets/{pet_id}/routines", headers=headers)
    assert resp.json()["total"] == 0


async def test_routine_validation(client):
    c, _ = client
    token = await _login(c, phone="13800138121")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    tomorrow = (date.today() + timedelta(days=1)).isoformat()
    resp = await c.post(
        f"/pets/{pet_id}/routines",
        json={"routine_type": "bath", "performed_at": tomorrow},
        headers=headers,
    )
    assert resp.status_code == 400


async def test_routine_cycle_update_and_status_enabled(client):
    """Cycle set + reminder_enabled=True + recent record → status computed."""
    c, _ = client
    token = await _login(c, phone="13800138122")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    today = date.today()

    # insert a record 29 days ago for bath
    await c.post(
        f"/pets/{pet_id}/routines",
        json={
            "routine_type": "bath",
            "performed_at": (today - timedelta(days=29)).isoformat(),
        },
        headers=headers,
    )
    # one record 5 days ago for nail_trim
    await c.post(
        f"/pets/{pet_id}/routines",
        json={
            "routine_type": "nail_trim",
            "performed_at": (today - timedelta(days=5)).isoformat(),
        },
        headers=headers,
    )

    # enable bath + nail_trim, leave grooming disabled
    resp = await c.put(
        f"/pets/{pet_id}/routine-cycle",
        json={
            "bath_cycle_days": 30,
            "nail_trim_cycle_days": 20,
            "grooming_cycle_days": 60,
            "bath_reminder_enabled": True,
            "nail_trim_reminder_enabled": True,
            "grooming_reminder_enabled": False,
        },
        headers=headers,
    )
    assert resp.status_code == 200
    cfg = resp.json()
    assert cfg["bath_cycle_days"] == 30
    assert cfg["bath_reminder_enabled"] is True
    assert cfg["grooming_reminder_enabled"] is False

    resp = await c.get(f"/pets/{pet_id}/routine-status", headers=headers)
    assert resp.status_code == 200
    st = resp.json()

    # bath: 29 days ago + 30 day cycle → 1 day remaining
    assert st["bath"]["reminder_enabled"] is True
    assert st["bath"]["cycle_days"] == 30
    assert st["bath"]["days_remaining"] == 1
    assert st["bath"]["is_overdue"] is False

    # nail_trim: 5 days ago + 20 day cycle → 15 days remaining
    assert st["nail_trim"]["reminder_enabled"] is True
    assert st["nail_trim"]["days_remaining"] == 15

    # grooming: disabled → all status fields None
    assert st["grooming"]["reminder_enabled"] is False
    assert st["grooming"]["next_due_at"] is None
    assert st["grooming"]["days_remaining"] is None
    assert st["grooming"]["is_overdue"] is None


async def test_routine_status_disabled_all(client):
    """reminder_enabled=False → all computed fields None, even with records."""
    c, _ = client
    token = await _login(c, phone="13800138123")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    today = date.today()
    for rt in ("bath", "nail_trim", "grooming"):
        await c.post(
            f"/pets/{pet_id}/routines",
            json={"routine_type": rt, "performed_at": (today - timedelta(days=1)).isoformat()},
            headers=headers,
        )

    # Default reminder_enabled should be False; verify status returns Nones.
    resp = await c.get(f"/pets/{pet_id}/routine-status", headers=headers)
    st = resp.json()
    for key in ("bath", "nail_trim", "grooming"):
        assert st[key]["reminder_enabled"] is False
        assert st[key]["next_due_at"] is None
        assert st[key]["days_remaining"] is None
        assert st[key]["is_overdue"] is None
        # last_performed_at is still informational even when disabled
        assert st[key]["last_performed_at"] is not None


async def test_routine_status_no_record_enabled(client):
    """reminder_enabled=True but no record → next_due_at / days_remaining None."""
    c, _ = client
    token = await _login(c, phone="13800138124")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    await c.put(
        f"/pets/{pet_id}/routine-cycle",
        json={"bath_reminder_enabled": True, "bath_cycle_days": 30},
        headers=headers,
    )

    resp = await c.get(f"/pets/{pet_id}/routine-status", headers=headers)
    st = resp.json()
    assert st["bath"]["reminder_enabled"] is True
    assert st["bath"]["last_performed_at"] is None
    assert st["bath"]["next_due_at"] is None
    assert st["bath"]["days_remaining"] is None
    assert st["bath"]["is_overdue"] is None


async def test_routine_cycle_validation(client):
    c, _ = client
    token = await _login(c, phone="13800138125")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    resp = await c.put(
        f"/pets/{pet_id}/routine-cycle",
        json={"bath_cycle_days": 500},
        headers=headers,
    )
    assert resp.status_code == 400


async def test_routine_forbidden_for_other_user(client):
    c, _ = client

    token_a = await _login(c, phone="13800138126")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet_id = await _create_pet(c, headers_a)

    token_b = await _login(c, phone="13800138127")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    # read
    resp = await c.get(f"/pets/{pet_id}/routines", headers=headers_b)
    assert resp.status_code == 403

    # write
    resp = await c.post(
        f"/pets/{pet_id}/routines",
        json={"routine_type": "bath", "performed_at": date.today().isoformat()},
        headers=headers_b,
    )
    assert resp.status_code == 403

    # status read
    resp = await c.get(f"/pets/{pet_id}/routine-status", headers=headers_b)
    assert resp.status_code == 403
