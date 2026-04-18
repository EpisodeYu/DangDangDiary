"""Step 5 health module — Deworming tests (split from legacy test_health.py).

Covers Deworming CRUD + cycle config + status calculation + no-record edge case.
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


async def test_deworming_crud_and_status(client):
    c, _ = client
    token = await _login(c, phone="13800138102")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    today = date.today()
    dewormed_date = (today - timedelta(days=20)).isoformat()

    resp = await c.post(
        f"/pets/{pet_id}/dewormings",
        json={"deworming_type": "internal", "dewormed_at": dewormed_date},
        headers=headers,
    )
    assert resp.status_code == 201
    internal_id = resp.json()["id"]

    resp = await c.post(
        f"/pets/{pet_id}/dewormings",
        json={"deworming_type": "combined", "dewormed_at": (today - timedelta(days=100)).isoformat()},
        headers=headers,
    )
    assert resp.status_code == 201

    resp = await c.get(f"/pets/{pet_id}/dewormings", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["total"] == 2

    resp = await c.put(
        f"/pets/{pet_id}/deworming-cycle",
        json={
            "internal_cycle_days": 30,
            "external_cycle_days": 30,
            "combined_cycle_days": 90,
            "internal_reminder_enabled": True,
            "external_reminder_enabled": False,
            "combined_reminder_enabled": True,
        },
        headers=headers,
    )
    assert resp.status_code == 200
    cfg = resp.json()
    assert cfg["internal_cycle_days"] == 30
    assert cfg["combined_cycle_days"] == 90
    assert cfg["internal_reminder_enabled"] is True
    assert cfg["external_reminder_enabled"] is False

    resp = await c.get(f"/pets/{pet_id}/deworming-status", headers=headers)
    assert resp.status_code == 200
    status = resp.json()

    assert status["internal"]["reminder_enabled"] is True
    assert status["internal"]["cycle_days"] == 30
    assert status["internal"]["next_due_at"] is not None
    assert status["internal"]["days_remaining"] == 10
    assert status["internal"]["is_overdue"] is False

    assert status["external"]["reminder_enabled"] is False
    assert status["external"]["next_due_at"] is None
    assert status["external"]["days_remaining"] is None
    assert status["external"]["is_overdue"] is None

    assert status["combined"]["reminder_enabled"] is True
    assert status["combined"]["days_remaining"] == -10
    assert status["combined"]["is_overdue"] is True

    new_date = (today - timedelta(days=5)).isoformat()
    resp = await c.put(
        f"/dewormings/{internal_id}",
        json={"deworming_type": "internal", "dewormed_at": new_date},
        headers=headers,
    )
    assert resp.status_code == 200

    resp = await c.delete(f"/dewormings/{internal_id}", headers=headers)
    assert resp.status_code == 204


async def test_deworming_status_no_record(client):
    c, _ = client
    token = await _login(c, phone="13800138103")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    await c.put(
        f"/pets/{pet_id}/deworming-cycle",
        json={"internal_reminder_enabled": True, "internal_cycle_days": 30},
        headers=headers,
    )

    resp = await c.get(f"/pets/{pet_id}/deworming-status", headers=headers)
    st = resp.json()
    assert st["internal"]["reminder_enabled"] is True
    assert st["internal"]["last_dewormed_at"] is None
    assert st["internal"]["next_due_at"] is None
    assert st["internal"]["is_overdue"] is None


async def test_deworming_cycle_validation(client):
    c, _ = client
    token = await _login(c, phone="13800138104")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    resp = await c.put(
        f"/pets/{pet_id}/deworming-cycle",
        json={"internal_cycle_days": 500},
        headers=headers,
    )
    assert resp.status_code == 400


async def test_deworming_forbidden_for_other_user(client):
    c, _ = client

    token_a = await _login(c, phone="13800138111")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet_id = await _create_pet(c, headers_a)

    token_b = await _login(c, phone="13800138112")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    resp = await c.get(f"/pets/{pet_id}/dewormings", headers=headers_b)
    assert resp.status_code == 403
