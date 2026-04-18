"""Step 5 health module — Weight tests (split from legacy test_health.py).

Covers Weight CRUD + validation + cross-user permission.
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


async def test_weight_crud(client):
    c, _ = client
    token = await _login(c, phone="13800138100")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    # create
    resp = await c.post(
        f"/pets/{pet_id}/weights",
        json={"weight_kg": "4.5", "recorded_at": "2024-01-15"},
        headers=headers,
    )
    assert resp.status_code == 201, resp.text
    w = resp.json()
    assert w["pet_id"] == pet_id
    assert float(w["weight_kg"]) == 4.5
    weight_id = w["id"]

    # list
    resp = await c.get(f"/pets/{pet_id}/weights", headers=headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 1
    assert data["weights"][0]["id"] == weight_id

    # update
    resp = await c.put(
        f"/weights/{weight_id}",
        json={"weight_kg": "4.8", "recorded_at": "2024-01-16"},
        headers=headers,
    )
    assert resp.status_code == 200
    assert float(resp.json()["weight_kg"]) == 4.8
    assert resp.json()["recorded_at"] == "2024-01-16"

    # delete
    resp = await c.delete(f"/weights/{weight_id}", headers=headers)
    assert resp.status_code == 204

    resp = await c.get(f"/pets/{pet_id}/weights", headers=headers)
    assert resp.json()["total"] == 0


async def test_weight_validation(client):
    c, _ = client
    token = await _login(c, phone="13800138101")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    # negative weight
    resp = await c.post(
        f"/pets/{pet_id}/weights",
        json={"weight_kg": "-1", "recorded_at": "2024-01-15"},
        headers=headers,
    )
    assert resp.status_code == 400

    # future date
    tomorrow = (date.today() + timedelta(days=1)).isoformat()
    resp = await c.post(
        f"/pets/{pet_id}/weights",
        json={"weight_kg": "4.0", "recorded_at": tomorrow},
        headers=headers,
    )
    assert resp.status_code == 400


async def test_weight_forbidden_for_other_user(client):
    c, _ = client

    token_a = await _login(c, phone="13800138109")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet_id = await _create_pet(c, headers_a)

    token_b = await _login(c, phone="13800138110")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    resp = await c.get(f"/pets/{pet_id}/weights", headers=headers_b)
    assert resp.status_code == 403
