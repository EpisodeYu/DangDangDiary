"""Step 6 timeline module — automated tests.

Covers:
  * First-page load + cursor pagination (older / newer)
  * Multi-pet filter, permission check
  * Anchor-month resolution (direct hit, older fallback, newer fallback, empty)
  * Date distribution endpoint
  * Stable sort under identical taken_at
"""

from datetime import date, datetime, timedelta

import pytest
from sqlalchemy import select
from sqlalchemy.ext.asyncio import async_sessionmaker, AsyncSession

import app.models  # noqa: F401  ensure all models registered with Base.metadata
from app.models.photo import Photo
from app.models.pet import Pet, PetMember, MemberRole
from app.models.user import User

from tests.conftest import _mock_sms_send

pytestmark = pytest.mark.asyncio


# ---------------- Helpers ----------------

async def _login(c, phone: str, code: str = "123456"):
    with _mock_sms_send(code):
        await c.post("/auth/send-code", json={"phone": phone})
    resp = await c.post("/auth/login", json={"phone": phone, "code": code})
    return resp.json()["access_token"]


async def _create_pet(c, headers, name: str = "橘子", pet_type: str = "cat") -> int:
    resp = await c.post(
        "/pets", json={"name": name, "pet_type": pet_type}, headers=headers,
    )
    assert resp.status_code == 201, resp.text
    return resp.json()["id"]


async def _get_user_id(engine, phone: str) -> int:
    sm = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        r = await s.execute(select(User).where(User.phone == phone))
        u = r.scalar_one()
        return u.id


async def _insert_photo(
    engine,
    *,
    pet_id: int,
    user_id: int,
    taken_at: date,
    created_at: datetime | None = None,
) -> int:
    sm = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)
    async with sm() as s:
        p = Photo(
            pet_id=pet_id,
            user_id=user_id,
            storage_key=f"{pet_id}/fake_{taken_at.isoformat()}_{(created_at or datetime.utcnow()).timestamp()}.jpg",
            thumbnail_key=f"{pet_id}/fake_{taken_at.isoformat()}_{(created_at or datetime.utcnow()).timestamp()}_thumb.jpg",
            taken_at=taken_at,
            created_at=created_at or datetime.utcnow(),
        )
        s.add(p)
        await s.commit()
        await s.refresh(p)
        return p.id


# ---------------- Tests ----------------


async def test_timeline_empty(client, test_engine):
    c, _ = client
    token = await _login(c, "13900100001")
    headers = {"Authorization": f"Bearer {token}"}

    resp = await c.get("/photos/timeline", headers=headers)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["groups"] == []
    assert data["total"] == 0
    assert data["prev_cursor"] is None
    assert data["next_cursor"] is None
    assert data["has_more_newer"] is False
    assert data["has_more_older"] is False
    assert data["date_range"]["earliest"] is None
    assert data["date_range"]["latest"] is None


async def test_timeline_first_page_and_pagination(client, test_engine):
    c, _ = client
    phone = "13900100002"
    token = await _login(c, phone)
    headers = {"Authorization": f"Bearer {token}"}
    pet_id = await _create_pet(c, headers, name="橘子", pet_type="cat")
    user_id = await _get_user_id(test_engine, phone)

    # Create 5 photos across 2 months.
    base = datetime(2024, 1, 10, 10, 0, 0)
    photo_ids: list[int] = []
    dates_created: list[tuple[date, datetime]] = [
        (date(2024, 1, 15), base + timedelta(days=5, hours=1)),
        (date(2024, 1, 10), base + timedelta(hours=2)),
        (date(2024, 1, 10), base + timedelta(hours=3)),  # same day, later created
        (date(2023, 12, 30), base - timedelta(days=10)),
        (date(2023, 12, 1), base - timedelta(days=20)),
    ]
    for d, c_at in dates_created:
        pid = await _insert_photo(
            test_engine, pet_id=pet_id, user_id=user_id, taken_at=d, created_at=c_at,
        )
        photo_ids.append(pid)

    # First page: limit=2
    resp = await c.get("/photos/timeline?limit=2", headers=headers)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["total"] == 5
    assert data["limit"] == 2
    # Expect the newest two photos: 2024-01-15, then 2024-01-10 (later created).
    all_photos = [p for g in data["groups"] for p in g["photos"]]
    assert len(all_photos) == 2
    assert all_photos[0]["taken_at"] == "2024-01-15"
    assert all_photos[1]["taken_at"] == "2024-01-10"
    assert data["has_more_older"] is True
    assert data["has_more_newer"] is False
    assert data["next_cursor"] is not None
    assert data["date_range"]["earliest"] == "2023-12-01"
    assert data["date_range"]["latest"] == "2024-01-15"

    # Continue older
    next_cursor = data["next_cursor"]
    resp = await c.get(
        f"/photos/timeline?limit=2&cursor={next_cursor}&direction=older",
        headers=headers,
    )
    assert resp.status_code == 200
    data2 = resp.json()
    photos2 = [p for g in data2["groups"] for p in g["photos"]]
    assert len(photos2) == 2
    # Next should be the second 2024-01-10 photo (earlier created) and 2023-12-30
    assert photos2[0]["taken_at"] == "2024-01-10"
    assert photos2[1]["taken_at"] == "2023-12-30"

    # Newer direction from the older tail cursor returns items newer than cursor.
    resp = await c.get(
        f"/photos/timeline?limit=10&cursor={data2['next_cursor']}&direction=newer",
        headers=headers,
    )
    assert resp.status_code == 200
    data3 = resp.json()
    photos3 = [p["id"] for g in data3["groups"] for p in g["photos"]]
    # Items strictly newer than 2023-12-30 tail: three Jan-2024 photos.
    assert len(photos3) == 3
    assert len(set(photos3)) == 3
    # Returned in DESC stable order.
    assert photos3[0] == photo_ids[0]  # 2024-01-15
    assert photos3[1] == photo_ids[2]  # 2024-01-10 later created
    assert photos3[2] == photo_ids[1]  # 2024-01-10 earlier created


async def test_timeline_pet_filter_and_permission(client, test_engine):
    c, _ = client
    phone_a = "13900100003"
    phone_b = "13900100004"
    token_a = await _login(c, phone_a)
    token_b = await _login(c, phone_b)
    ha = {"Authorization": f"Bearer {token_a}"}
    hb = {"Authorization": f"Bearer {token_b}"}
    user_a = await _get_user_id(test_engine, phone_a)
    user_b = await _get_user_id(test_engine, phone_b)

    pet_a1 = await _create_pet(c, ha, name="A1")
    pet_a2 = await _create_pet(c, ha, name="A2")
    pet_b1 = await _create_pet(c, hb, name="B1")

    d = date(2024, 2, 1)
    await _insert_photo(
        test_engine, pet_id=pet_a1, user_id=user_a, taken_at=d,
        created_at=datetime(2024, 2, 1, 12),
    )
    await _insert_photo(
        test_engine, pet_id=pet_a2, user_id=user_a, taken_at=d,
        created_at=datetime(2024, 2, 1, 13),
    )
    await _insert_photo(
        test_engine, pet_id=pet_b1, user_id=user_b, taken_at=d,
        created_at=datetime(2024, 2, 1, 14),
    )

    # User A, no filter → sees 2 own photos only
    resp = await c.get("/photos/timeline", headers=ha)
    assert resp.status_code == 200
    assert resp.json()["total"] == 2

    # User A, filter pet_a1
    resp = await c.get(f"/photos/timeline?pet_ids={pet_a1}", headers=ha)
    assert resp.status_code == 200
    data = resp.json()
    assert data["total"] == 1
    photos = [p for g in data["groups"] for p in g["photos"]]
    assert photos[0]["pet_id"] == pet_a1
    assert photos[0]["pet_name"] == "A1"

    # User A requesting pet_b1 → 403
    resp = await c.get(f"/photos/timeline?pet_ids={pet_b1}", headers=ha)
    assert resp.status_code == 403
    assert resp.json()["code"] == "PET_FORBIDDEN"


async def test_timeline_anchor_month_direct_hit(client, test_engine):
    c, _ = client
    phone = "13900100005"
    token = await _login(c, phone)
    h = {"Authorization": f"Bearer {token}"}
    uid = await _get_user_id(test_engine, phone)
    pet_id = await _create_pet(c, h)

    # Photos in 2024-03, 2024-05
    await _insert_photo(test_engine, pet_id=pet_id, user_id=uid, taken_at=date(2024, 3, 10))
    await _insert_photo(test_engine, pet_id=pet_id, user_id=uid, taken_at=date(2024, 5, 1))

    resp = await c.get("/photos/timeline?anchor_month=2024-03", headers=h)
    assert resp.status_code == 200
    data = resp.json()
    assert data["requested_anchor_month"] == "2024-03"
    assert data["resolved_anchor_month"] == "2024-03"
    photos = [p for g in data["groups"] for p in g["photos"]]
    assert len(photos) == 1
    assert photos[0]["taken_at"] == "2024-03-10"


async def test_timeline_anchor_month_fallback_older(client, test_engine):
    c, _ = client
    phone = "13900100006"
    token = await _login(c, phone)
    h = {"Authorization": f"Bearer {token}"}
    uid = await _get_user_id(test_engine, phone)
    pet_id = await _create_pet(c, h)

    await _insert_photo(test_engine, pet_id=pet_id, user_id=uid, taken_at=date(2024, 2, 15))
    # Request a month with no photos; should fall back to 2024-02
    resp = await c.get("/photos/timeline?anchor_month=2024-04", headers=h)
    assert resp.status_code == 200
    data = resp.json()
    assert data["requested_anchor_month"] == "2024-04"
    assert data["resolved_anchor_month"] == "2024-02"


async def test_timeline_anchor_month_fallback_newer(client, test_engine):
    c, _ = client
    phone = "13900100007"
    token = await _login(c, phone)
    h = {"Authorization": f"Bearer {token}"}
    uid = await _get_user_id(test_engine, phone)
    pet_id = await _create_pet(c, h)

    await _insert_photo(test_engine, pet_id=pet_id, user_id=uid, taken_at=date(2024, 6, 1))
    # Request an older month: no older photos, fall back to newer month
    resp = await c.get("/photos/timeline?anchor_month=2023-01", headers=h)
    assert resp.status_code == 200
    data = resp.json()
    assert data["requested_anchor_month"] == "2023-01"
    assert data["resolved_anchor_month"] == "2024-06"


async def test_timeline_invalid_params(client, test_engine):
    c, _ = client
    token = await _login(c, "13900100008")
    h = {"Authorization": f"Bearer {token}"}

    # cursor + anchor_month mutually exclusive
    resp = await c.get(
        "/photos/timeline?cursor=abc&anchor_month=2024-01", headers=h,
    )
    assert resp.status_code == 400

    # bad cursor
    resp = await c.get("/photos/timeline?cursor=not_base64_!!!", headers=h)
    assert resp.status_code == 400

    # bad anchor_month
    resp = await c.get("/photos/timeline?anchor_month=2024-13", headers=h)
    assert resp.status_code == 400

    # bad direction
    resp = await c.get("/photos/timeline?direction=sideways", headers=h)
    assert resp.status_code == 400

    # limit > MAX
    resp = await c.get("/photos/timeline?limit=1000", headers=h)
    assert resp.status_code == 400

    # bad pet_ids
    resp = await c.get("/photos/timeline?pet_ids=abc,1", headers=h)
    assert resp.status_code == 400


async def test_timeline_dates(client, test_engine):
    c, _ = client
    phone = "13900100009"
    token = await _login(c, phone)
    h = {"Authorization": f"Bearer {token}"}
    uid = await _get_user_id(test_engine, phone)
    pet_id = await _create_pet(c, h)

    for d in [date(2024, 1, 5), date(2024, 1, 9), date(2023, 12, 30)]:
        await _insert_photo(
            test_engine, pet_id=pet_id, user_id=uid, taken_at=d,
        )

    resp = await c.get("/photos/timeline/dates", headers=h)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    months = {m["date"]: m["count"] for m in data["months"]}
    assert months == {"2024-01": 2, "2023-12": 1}
    assert data["months"][0]["date"] == "2024-01"  # newest first
    assert data["months"][0]["label"] == "2024年1月"
    assert data["date_range"]["earliest"] == "2023-12-30"
    assert data["date_range"]["latest"] == "2024-01-09"


async def test_timeline_stable_sort_same_day(client, test_engine):
    """Same taken_at: ordering must be deterministic by created_at DESC then id DESC."""
    c, _ = client
    phone = "13900100010"
    token = await _login(c, phone)
    h = {"Authorization": f"Bearer {token}"}
    uid = await _get_user_id(test_engine, phone)
    pet_id = await _create_pet(c, h)

    d = date(2024, 4, 1)
    # Intentionally insert out of order; assert they come back in stable order.
    id_mid = await _insert_photo(
        test_engine, pet_id=pet_id, user_id=uid, taken_at=d,
        created_at=datetime(2024, 4, 1, 10, 0, 0),
    )
    id_old = await _insert_photo(
        test_engine, pet_id=pet_id, user_id=uid, taken_at=d,
        created_at=datetime(2024, 4, 1, 9, 0, 0),
    )
    id_new = await _insert_photo(
        test_engine, pet_id=pet_id, user_id=uid, taken_at=d,
        created_at=datetime(2024, 4, 1, 11, 0, 0),
    )

    resp = await c.get("/photos/timeline", headers=h)
    assert resp.status_code == 200
    ids = [p["id"] for g in resp.json()["groups"] for p in g["photos"]]
    assert ids == [id_new, id_mid, id_old]
