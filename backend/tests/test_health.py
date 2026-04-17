"""Step 5 health module — automated tests.

Covers:
  * Weight CRUD
  * Deworming CRUD + cycle config + status calculation
  * Vaccination CRUD + preset lookup
"""
import pytest
from datetime import date, timedelta

# Ensure all ORM models are registered with Base.metadata before
# the in-memory SQLite schema is created by the `test_engine` fixture.
import app.models  # noqa: F401

from tests.conftest import _mock_sms_send

pytestmark = pytest.mark.asyncio


# ── helpers ──

async def _login(c, phone="13800138100", code="123456"):
    with _mock_sms_send(code):
        await c.post("/auth/send-code", json={"phone": phone})
    resp = await c.post("/auth/login", json={"phone": phone, "code": code})
    return resp.json()["access_token"]


async def _create_pet(c, headers, name="橘子", pet_type="cat"):
    resp = await c.post("/pets", json={"name": name, "pet_type": pet_type}, headers=headers)
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


# ---------------- Weight ----------------

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


# ---------------- Deworming ----------------

async def test_deworming_crud_and_status(client):
    c, _ = client
    token = await _login(c, phone="13800138102")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    today = date.today()
    dewormed_date = (today - timedelta(days=20)).isoformat()

    # create internal
    resp = await c.post(
        f"/pets/{pet_id}/dewormings",
        json={"deworming_type": "internal", "dewormed_at": dewormed_date},
        headers=headers,
    )
    assert resp.status_code == 201
    internal_id = resp.json()["id"]

    # create combined (overdue)
    resp = await c.post(
        f"/pets/{pet_id}/dewormings",
        json={"deworming_type": "combined", "dewormed_at": (today - timedelta(days=100)).isoformat()},
        headers=headers,
    )
    assert resp.status_code == 201

    # list
    resp = await c.get(f"/pets/{pet_id}/dewormings", headers=headers)
    assert resp.status_code == 200
    assert resp.json()["total"] == 2

    # update cycles + enable reminders
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

    # status
    resp = await c.get(f"/pets/{pet_id}/deworming-status", headers=headers)
    assert resp.status_code == 200
    status = resp.json()

    # internal: enabled, has record + cycle → should be valid
    assert status["internal"]["reminder_enabled"] is True
    assert status["internal"]["cycle_days"] == 30
    assert status["internal"]["next_due_at"] is not None
    # dewormed 20 days ago + 30 days = 10 days remaining
    assert status["internal"]["days_remaining"] == 10
    assert status["internal"]["is_overdue"] is False

    # external: disabled → all null
    assert status["external"]["reminder_enabled"] is False
    assert status["external"]["next_due_at"] is None
    assert status["external"]["days_remaining"] is None
    assert status["external"]["is_overdue"] is None

    # combined: enabled, has record 100 days ago + 90 days cycle → overdue by 10
    assert status["combined"]["reminder_enabled"] is True
    assert status["combined"]["days_remaining"] == -10
    assert status["combined"]["is_overdue"] is True

    # update record
    new_date = (today - timedelta(days=5)).isoformat()
    resp = await c.put(
        f"/dewormings/{internal_id}",
        json={"deworming_type": "internal", "dewormed_at": new_date},
        headers=headers,
    )
    assert resp.status_code == 200

    # delete
    resp = await c.delete(f"/dewormings/{internal_id}", headers=headers)
    assert resp.status_code == 204


async def test_deworming_status_no_record(client):
    c, _ = client
    token = await _login(c, phone="13800138103")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    # enable internal reminder but no record
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


# ---------------- Vaccination ----------------

async def test_vaccination_crud(client):
    c, _ = client
    token = await _login(c, phone="13800138105")
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers)

    resp = await c.post(
        f"/pets/{pet_id}/vaccinations",
        json={"vaccine_type": "猫三联疫苗", "vaccinated_at": "2024-01-15"},
        headers=headers,
    )
    assert resp.status_code == 201
    vac_id = resp.json()["id"]

    resp = await c.get(f"/pets/{pet_id}/vaccinations", headers=headers)
    assert resp.json()["total"] == 1

    resp = await c.put(
        f"/vaccinations/{vac_id}",
        json={"vaccine_type": "狂犬病疫苗", "vaccinated_at": "2024-02-20"},
        headers=headers,
    )
    assert resp.status_code == 200
    assert resp.json()["vaccine_type"] == "狂犬病疫苗"

    resp = await c.delete(f"/vaccinations/{vac_id}", headers=headers)
    assert resp.status_code == 204


async def test_vaccine_type_presets(client):
    c, _ = client
    token = await _login(c, phone="13800138106")
    headers = {"Authorization": f"Bearer {token}"}

    resp = await c.get("/vaccine-types?pet_type=cat", headers=headers)
    assert resp.status_code == 200
    data = resp.json()
    assert data["pet_type"] == "cat"
    assert "猫三联疫苗" in data["preset_types"]
    assert "狂犬病疫苗" in data["preset_types"]
    assert data["preset_types"][0] == "猫三联疫苗"

    resp = await c.get("/vaccine-types?pet_type=dog", headers=headers)
    data = resp.json()
    assert data["pet_type"] == "dog"
    assert "犬二联疫苗" in data["preset_types"]
    assert data["preset_types"][0] == "狂犬病疫苗"

    resp = await c.get("/vaccine-types?pet_type=fish", headers=headers)
    assert resp.status_code == 400


# ---------------- Forbidden ----------------

async def test_forbidden_for_other_user(client):
    c, _ = client

    # user A creates a pet
    token_a = await _login(c, phone="13800138107")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet_id = await _create_pet(c, headers_a)

    # user B tries to access
    token_b = await _login(c, phone="13800138108")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    resp = await c.get(f"/pets/{pet_id}/weights", headers=headers_b)
    assert resp.status_code == 403
