"""Unit tests for the auth dependency split (Step 8 Chunk B-6 / §1.1 rule 5).

`get_current_user_id` must decode the JWT and return the user id WITHOUT
hitting the database, saving one roundtrip on every authenticated
request. Routes migrated to this lightweight dependency (pets / photos
/ health) therefore never issue `SELECT users WHERE id = ?`.

We assert the contract by wiring a SQLAlchemy ``do_execute`` hook to
the engine used by the test client and counting statements that target
the ``users`` table during a ``GET /pets`` call.
"""
from __future__ import annotations

from contextlib import contextmanager

import pytest
from sqlalchemy import event

import app.models  # noqa: F401  ensure all ORM models are registered with Base
from tests.conftest import _mock_sms_send

pytestmark = pytest.mark.asyncio


@contextmanager
def _count_users_queries(engine):
    """Yield a mutable counter of ``users``-table statements while active."""
    counter = [0]

    def _before_cursor_execute(_conn, _cursor, statement, _params, _ctx, _em):
        # Substring match is enough — the model emits fully-qualified
        # column lists like ``SELECT users.id, users.phone, ... FROM users``.
        if "from users" in statement.lower() or "users.id" in statement.lower():
            counter[0] += 1

    event.listen(engine.sync_engine, "before_cursor_execute", _before_cursor_execute)
    try:
        yield counter
    finally:
        event.remove(
            engine.sync_engine, "before_cursor_execute", _before_cursor_execute
        )


async def _login(ac, store, *, phone: str, code: str = "654321") -> str:
    with _mock_sms_send(code):
        await ac.post("/auth/send-code", json={"phone": phone})
    store[f"sms:verify:{phone}"] = code
    resp = await ac.post("/auth/login", json={"phone": phone, "code": code})
    assert resp.status_code == 200, resp.text
    return resp.json()["access_token"]


async def test_list_pets_does_not_query_users_table(client, test_engine):
    """GET /pets uses get_current_user_id → no SELECT against users."""
    ac, store = client

    access = await _login(ac, store, phone="13900002222")
    headers = {"Authorization": f"Bearer {access}"}

    create = await ac.post(
        "/pets",
        json={"name": "豆豆", "pet_type": "cat"},
        headers=headers,
    )
    assert create.status_code == 201, create.text

    with _count_users_queries(test_engine) as counter:
        resp = await ac.get("/pets", headers=headers)

    assert resp.status_code == 200
    assert counter[0] == 0, (
        "GET /pets should authenticate via JWT decode only; it issued "
        f"{counter[0]} statement(s) against the users table."
    )


async def test_get_me_still_loads_user_row(client, test_engine):
    """GET /auth/me keeps get_current_user → it MUST still load the row.

    Inverse assertion: make sure the split did not accidentally remove a
    DB load that endpoint genuinely needs to serialize the `User` ORM
    object.
    """
    ac, store = client
    access = await _login(ac, store, phone="13900003333")
    headers = {"Authorization": f"Bearer {access}"}

    with _count_users_queries(test_engine) as counter:
        resp = await ac.get("/auth/me", headers=headers)

    assert resp.status_code == 200
    assert counter[0] >= 1, (
        "GET /auth/me still depends on get_current_user and must load "
        "the User row; observed zero users-table statements."
    )


async def test_invalid_token_is_rejected_without_db_hit(client, test_engine):
    """Bad tokens short-circuit at JWT decode; no users query should run."""
    ac, _store = client

    with _count_users_queries(test_engine) as counter:
        resp = await ac.get(
            "/pets", headers={"Authorization": "Bearer not-a-real-jwt"}
        )

    assert resp.status_code == 401
    assert resp.json()["code"] == "INVALID_ACCESS_TOKEN"
    assert counter[0] == 0
