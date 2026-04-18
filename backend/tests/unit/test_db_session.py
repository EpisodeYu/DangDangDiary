"""Verify §1.1 rule 1: GET routes issue SELECT but no COMMIT.

Uses a SQLAlchemy event listener on the `Session` class to count commits
while exercising a read-only endpoint through the full FastAPI pipeline.
"""

import pytest
from sqlalchemy import event
from sqlalchemy.orm import Session

from tests.conftest import _mock_sms_send  # noqa: F401 - reused mock helper


@pytest.mark.asyncio
async def test_get_route_does_not_commit(client):
    """GET /pets must not call session.commit()."""
    ac, store = client

    # --- Prepare an authenticated user + one pet (writes will commit normally). ---
    with _mock_sms_send("111111"):
        await ac.post("/auth/send-code", json={"phone": "13900001111"})
    store["sms:verify:13900001111"] = "111111"
    login = await ac.post("/auth/login", json={"phone": "13900001111", "code": "111111"})
    access_token = login.json()["access_token"]
    headers = {"Authorization": f"Bearer {access_token}"}

    # Seed one pet so the GET route has something to return.
    create_resp = await ac.post(
        "/pets",
        json={"name": "小白", "pet_type": "cat"},
        headers=headers,
    )
    assert create_resp.status_code == 201

    # --- Count commits during a GET request only. ---
    commit_count = 0

    @event.listens_for(Session, "after_commit")
    def _on_commit(_session):  # noqa: WPS430
        nonlocal commit_count
        commit_count += 1

    try:
        list_resp = await ac.get("/pets", headers=headers)
        assert list_resp.status_code == 200
    finally:
        event.remove(Session, "after_commit", _on_commit)

    assert commit_count == 0, (
        f"GET /pets issued {commit_count} COMMIT(s); read-only requests must not commit."
    )
