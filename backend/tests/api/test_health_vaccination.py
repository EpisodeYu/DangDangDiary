"""Step 5 health module — Vaccination tests (split from legacy test_health.py).

Covers Vaccination CRUD + preset lookup + cross-user permission.
"""
import pytest

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


async def test_vaccination_forbidden_for_other_user(client):
    c, _ = client

    token_a = await _login(c, phone="13800138113")
    headers_a = {"Authorization": f"Bearer {token_a}"}
    pet_id = await _create_pet(c, headers_a)

    token_b = await _login(c, phone="13800138114")
    headers_b = {"Authorization": f"Bearer {token_b}"}

    resp = await c.get(f"/pets/{pet_id}/vaccinations", headers=headers_b)
    assert resp.status_code == 403
