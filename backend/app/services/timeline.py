"""Step 6 — photo timeline service.

Provides cursor-based pagination and month anchor resolution for the
`GET /photos/timeline` and `GET /photos/timeline/dates` endpoints.

Stable sort order (applied everywhere):
    taken_at DESC, created_at DESC, id DESC

Cursor encoding:
    Base64-url JSON of {"taken_at": "YYYY-MM-DD",
                        "created_at": "YYYY-MM-DDTHH:MM:SS.fff",
                        "id": int}
"""

from __future__ import annotations

import base64
import json
from collections import OrderedDict
from dataclasses import dataclass
from datetime import date, datetime
from typing import Iterable

from sqlalchemy import and_, extract, func, literal, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import AppException
from app.models.pet import Pet, PetMember
from app.models.photo import Photo
from app.models.user import User
from app.schemas.photo import (
    DateDistributionItem,
    TimelineDateRange,
    TimelineDatesResponse,
    TimelineGroup,
    TimelinePhotoItem,
    TimelineWindowResponse,
)
from app.services.storage import build_thumbnail_url


DEFAULT_LIMIT = 40
MAX_LIMIT = 100


# ---------------- Cursor helpers ----------------


@dataclass(frozen=True)
class _Cursor:
    taken_at: date
    created_at: datetime
    id: int


def _encode_cursor(photo: Photo | TimelinePhotoItem) -> str:
    payload = {
        "taken_at": photo.taken_at.isoformat(),
        "created_at": photo.created_at.isoformat(),
        "id": int(photo.id),
    }
    raw = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    return base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")


def _decode_cursor(raw: str) -> _Cursor:
    try:
        decoded = base64.urlsafe_b64decode(raw.encode("ascii") + b"==")
        payload = json.loads(decoded.decode("utf-8"))
        return _Cursor(
            taken_at=date.fromisoformat(payload["taken_at"]),
            created_at=datetime.fromisoformat(payload["created_at"]),
            id=int(payload["id"]),
        )
    except Exception as exc:  # noqa: BLE001
        raise AppException(400, "INVALID_CURSOR", "游标格式不正确") from exc


# ---------------- Query helpers ----------------


def _month_label(key: str) -> str:
    # "2024-01" -> "2024年1月"
    year, month = key.split("-")
    return f"{int(year)}年{int(month)}月"


def _month_key(d: date) -> str:
    return f"{d.year:04d}-{d.month:02d}"


async def _resolve_accessible_pet_ids(
    db: AsyncSession, user_id: int, requested: list[int] | None,
) -> list[int]:
    """Return the list of pet_ids the user may query.

    - `requested=None` (or empty) means "all accessible pets".
    - If any requested id is not accessible, raises 403.
    """
    result = await db.execute(
        select(PetMember.pet_id).where(PetMember.user_id == user_id)
    )
    accessible = {pid for (pid,) in result.all()}

    if not requested:
        return list(accessible)

    requested_set = set(requested)
    forbidden = requested_set - accessible
    if forbidden:
        raise AppException(
            403, "PET_FORBIDDEN", "您无权访问部分宠物档案",
            details={"forbidden_pet_ids": sorted(forbidden)},
        )
    return list(requested_set)


def _photo_to_item(
    photo: Photo,
    pet_name: str,
    pet_type: str,
    uploader_nickname: str | None,
) -> TimelinePhotoItem:
    thumb_url = (
        build_thumbnail_url(photo.thumbnail_key) if photo.thumbnail_key else ""
    )
    sm_url = (
        build_thumbnail_url(photo.thumbnail_sm_key) if photo.thumbnail_sm_key else ""
    )
    return TimelinePhotoItem(
        id=photo.id,
        pet_id=photo.pet_id,
        pet_name=pet_name,
        pet_type=pet_type,
        uploader_id=photo.user_id,
        uploader_nickname=uploader_nickname,
        thumbnail_url=thumb_url,
        thumbnail_sm_url=sm_url,
        taken_at=photo.taken_at,
        created_at=photo.created_at,
    )


async def _load_pet_meta(
    db: AsyncSession, pet_ids: Iterable[int],
) -> dict[int, tuple[str, str]]:
    ids = list({int(p) for p in pet_ids})
    if not ids:
        return {}
    result = await db.execute(
        select(Pet.id, Pet.name, Pet.pet_type).where(Pet.id.in_(ids))
    )
    return {
        pid: (name, pet_type.value if hasattr(pet_type, "value") else str(pet_type))
        for pid, name, pet_type in result.all()
    }


async def _load_uploader_nicknames(
    db: AsyncSession, user_ids: Iterable[int],
) -> dict[int, str | None]:
    ids = list({int(u) for u in user_ids})
    if not ids:
        return {}
    result = await db.execute(
        select(User.id, User.nickname).where(User.id.in_(ids))
    )
    return {uid: nickname for uid, nickname in result.all()}


def _group_by_month(photos: list[TimelinePhotoItem]) -> list[TimelineGroup]:
    bucket: "OrderedDict[str, list[TimelinePhotoItem]]" = OrderedDict()
    for p in photos:
        key = _month_key(p.taken_at)
        bucket.setdefault(key, []).append(p)
    return [
        TimelineGroup(date=key, label=_month_label(key), photos=items)
        for key, items in bucket.items()
    ]


async def _date_range(db: AsyncSession, pet_ids: list[int]) -> TimelineDateRange:
    if not pet_ids:
        return TimelineDateRange(earliest=None, latest=None)
    result = await db.execute(
        select(func.min(Photo.taken_at), func.max(Photo.taken_at)).where(
            Photo.pet_id.in_(pet_ids)
        )
    )
    earliest, latest = result.one()
    return TimelineDateRange(earliest=earliest, latest=latest)


async def _total_count(db: AsyncSession, pet_ids: list[int]) -> int:
    if not pet_ids:
        return 0
    result = await db.execute(
        select(func.count()).select_from(Photo).where(Photo.pet_id.in_(pet_ids))
    )
    return int(result.scalar() or 0)


# ---------------- Core fetch logic ----------------


def _older_than_expr(cursor: _Cursor):
    """Predicate: photo is strictly older than cursor under the stable sort.

    Stable key (taken_at, created_at, id) desc means "older" means
    (taken_at, created_at, id) < cursor tuple.
    """
    return or_(
        Photo.taken_at < cursor.taken_at,
        and_(
            Photo.taken_at == cursor.taken_at,
            Photo.created_at < cursor.created_at,
        ),
        and_(
            Photo.taken_at == cursor.taken_at,
            Photo.created_at == cursor.created_at,
            Photo.id < cursor.id,
        ),
    )


def _newer_than_expr(cursor: _Cursor):
    return or_(
        Photo.taken_at > cursor.taken_at,
        and_(
            Photo.taken_at == cursor.taken_at,
            Photo.created_at > cursor.created_at,
        ),
        and_(
            Photo.taken_at == cursor.taken_at,
            Photo.created_at == cursor.created_at,
            Photo.id > cursor.id,
        ),
    )


async def _fetch_window(
    db: AsyncSession,
    pet_ids: list[int],
    *,
    start_from: _Cursor | None,
    direction: str,
    inclusive: bool,
    limit: int,
) -> list[Photo]:
    """Fetch `limit` photos in `direction`.

    - direction=older: items (strictly or inclusively) older than `start_from`,
      result ordered DESC.
    - direction=newer: items strictly newer than `start_from`, ordered ASC
      (closest to cursor first), then returned reversed so caller can merge
      into a DESC-ordered timeline.
    """
    if not pet_ids:
        return []

    stmt = select(Photo).where(Photo.pet_id.in_(pet_ids))

    if direction == "older":
        if start_from is not None:
            if inclusive:
                stmt = stmt.where(
                    or_(
                        _older_than_expr(start_from),
                        and_(
                            Photo.taken_at == start_from.taken_at,
                            Photo.created_at == start_from.created_at,
                            Photo.id == start_from.id,
                        ),
                    )
                )
            else:
                stmt = stmt.where(_older_than_expr(start_from))
        stmt = stmt.order_by(
            Photo.taken_at.desc(), Photo.created_at.desc(), Photo.id.desc()
        ).limit(limit)
        rows = (await db.execute(stmt)).scalars().all()
        return list(rows)

    if direction == "newer":
        if start_from is None:
            raise AppException(400, "INVALID_CURSOR", "direction=newer 必须传游标")
        stmt = stmt.where(_newer_than_expr(start_from)).order_by(
            Photo.taken_at.asc(), Photo.created_at.asc(), Photo.id.asc()
        ).limit(limit)
        rows = (await db.execute(stmt)).scalars().all()
        rows = list(rows)
        rows.reverse()
        return rows

    raise AppException(400, "INVALID_DIRECTION", "direction 只能是 older 或 newer")


async def _has_more_older(db: AsyncSession, pet_ids: list[int], tail: _Cursor) -> bool:
    if not pet_ids:
        return False
    stmt = (
        select(literal(1))
        .select_from(Photo)
        .where(Photo.pet_id.in_(pet_ids))
        .where(_older_than_expr(tail))
        .limit(1)
    )
    return (await db.execute(stmt)).first() is not None


async def _has_more_newer(db: AsyncSession, pet_ids: list[int], head: _Cursor) -> bool:
    if not pet_ids:
        return False
    stmt = (
        select(literal(1))
        .select_from(Photo)
        .where(Photo.pet_id.in_(pet_ids))
        .where(_newer_than_expr(head))
        .limit(1)
    )
    return (await db.execute(stmt)).first() is not None


# ---------------- Anchor month resolution ----------------


def _validate_anchor_month_format(anchor_month: str) -> tuple[int, int]:
    try:
        parts = anchor_month.split("-")
        if len(parts) != 2:
            raise ValueError
        year_i, month_i = int(parts[0]), int(parts[1])
        if not (1 <= month_i <= 12) or year_i < 1:
            raise ValueError
        return year_i, month_i
    except Exception as exc:  # noqa: BLE001
        raise AppException(
            400, "INVALID_ANCHOR_MONTH", "anchor_month 必须为 YYYY-MM 格式",
        ) from exc


async def _resolve_anchor_cursor(
    db: AsyncSession, pet_ids: list[int], anchor_month: str,
) -> tuple[_Cursor | None, str | None]:
    """Find the starting cursor for an anchor-month request.

    Returns (cursor, resolved_month_key) where cursor is the first (newest)
    photo that should appear at the top of the returned window, and
    resolved_month_key is the month that was actually hit after fallback.

    Priority:
      1. Newest photo in target month.
      2. Newest photo in any month older than target.
      3. Oldest photo in any month newer than target (so that the window
         naturally scrolls up toward recent data).
    """
    year_i, month_i = _validate_anchor_month_format(anchor_month)

    if not pet_ids:
        return None, None

    first_day = date(year_i, month_i, 1)
    if month_i == 12:
        first_day_next = date(year_i + 1, 1, 1)
    else:
        first_day_next = date(year_i, month_i + 1, 1)

    base = select(Photo).where(Photo.pet_id.in_(pet_ids))

    # 1. Hit the month directly.
    stmt = (
        base.where(Photo.taken_at >= first_day, Photo.taken_at < first_day_next)
        .order_by(Photo.taken_at.desc(), Photo.created_at.desc(), Photo.id.desc())
        .limit(1)
    )
    hit = (await db.execute(stmt)).scalar_one_or_none()
    if hit is not None:
        return (
            _Cursor(taken_at=hit.taken_at, created_at=hit.created_at, id=hit.id),
            _month_key(hit.taken_at),
        )

    # 2. Fallback: newest photo strictly older than target month.
    stmt = (
        base.where(Photo.taken_at < first_day)
        .order_by(Photo.taken_at.desc(), Photo.created_at.desc(), Photo.id.desc())
        .limit(1)
    )
    hit = (await db.execute(stmt)).scalar_one_or_none()
    if hit is not None:
        return (
            _Cursor(taken_at=hit.taken_at, created_at=hit.created_at, id=hit.id),
            _month_key(hit.taken_at),
        )

    # 3. Fallback: oldest photo in a month newer than target.
    stmt = (
        base.where(Photo.taken_at >= first_day_next)
        .order_by(Photo.taken_at.asc(), Photo.created_at.asc(), Photo.id.asc())
        .limit(1)
    )
    hit = (await db.execute(stmt)).scalar_one_or_none()
    if hit is not None:
        return (
            _Cursor(taken_at=hit.taken_at, created_at=hit.created_at, id=hit.id),
            _month_key(hit.taken_at),
        )

    return None, None


# ---------------- Public entrypoints ----------------


async def get_timeline_window(
    db: AsyncSession,
    user_id: int,
    *,
    requested_pet_ids: list[int] | None,
    limit: int,
    cursor_raw: str | None,
    direction: str,
    anchor_month: str | None,
) -> TimelineWindowResponse:
    if cursor_raw is not None and anchor_month is not None:
        raise AppException(
            400, "INVALID_QUERY", "cursor 和 anchor_month 不能同时使用",
        )
    if direction not in ("older", "newer"):
        raise AppException(400, "INVALID_DIRECTION", "direction 只能是 older 或 newer")
    if limit < 1 or limit > MAX_LIMIT:
        raise AppException(
            400, "INVALID_LIMIT", f"limit 必须在 1 到 {MAX_LIMIT} 之间",
        )

    # Validate opaque inputs up-front so bad syntax is rejected even when the
    # user has no accessible pets (empty-result fast path).
    parsed_cursor: _Cursor | None = None
    if cursor_raw is not None:
        parsed_cursor = _decode_cursor(cursor_raw)
    if anchor_month is not None:
        _validate_anchor_month_format(anchor_month)

    pet_ids = await _resolve_accessible_pet_ids(db, user_id, requested_pet_ids)

    date_range = await _date_range(db, pet_ids)
    total = await _total_count(db, pet_ids)

    if not pet_ids:
        return TimelineWindowResponse(
            groups=[],
            total=0,
            limit=limit,
            prev_cursor=None,
            next_cursor=None,
            has_more_newer=False,
            has_more_older=False,
            requested_anchor_month=anchor_month,
            resolved_anchor_month=None,
            date_range=date_range,
        )

    requested_anchor_month = anchor_month
    resolved_anchor_month: str | None = None

    if anchor_month is not None:
        anchor_cursor, resolved_anchor_month = await _resolve_anchor_cursor(
            db, pet_ids, anchor_month,
        )
        if anchor_cursor is None:
            return TimelineWindowResponse(
                groups=[],
                total=total,
                limit=limit,
                prev_cursor=None,
                next_cursor=None,
                has_more_newer=False,
                has_more_older=False,
                requested_anchor_month=requested_anchor_month,
                resolved_anchor_month=None,
                date_range=date_range,
            )
        photos = await _fetch_window(
            db,
            pet_ids,
            start_from=anchor_cursor,
            direction="older",
            inclusive=True,
            limit=limit,
        )
    elif parsed_cursor is not None:
        photos = await _fetch_window(
            db,
            pet_ids,
            start_from=parsed_cursor,
            direction=direction,
            inclusive=False,
            limit=limit,
        )
    else:
        # First page load
        photos = await _fetch_window(
            db,
            pet_ids,
            start_from=None,
            direction="older",
            inclusive=False,
            limit=limit,
        )

    if not photos:
        return TimelineWindowResponse(
            groups=[],
            total=total,
            limit=limit,
            prev_cursor=None,
            next_cursor=None,
            has_more_newer=False,
            has_more_older=False,
            requested_anchor_month=requested_anchor_month,
            resolved_anchor_month=resolved_anchor_month,
            date_range=date_range,
        )

    pet_meta = await _load_pet_meta(db, (p.pet_id for p in photos))
    uploader_map = await _load_uploader_nicknames(
        db, (p.user_id for p in photos)
    )
    items = [
        _photo_to_item(
            photo,
            pet_meta.get(photo.pet_id, (f"宠物#{photo.pet_id}", "cat"))[0],
            pet_meta.get(photo.pet_id, (f"宠物#{photo.pet_id}", "cat"))[1],
            uploader_map.get(photo.user_id),
        )
        for photo in photos
    ]
    # `items` is already DESC by stable key.
    groups = _group_by_month(items)

    head = photos[0]
    tail = photos[-1]
    head_cursor = _Cursor(
        taken_at=head.taken_at, created_at=head.created_at, id=head.id,
    )
    tail_cursor = _Cursor(
        taken_at=tail.taken_at, created_at=tail.created_at, id=tail.id,
    )
    has_more_newer = await _has_more_newer(db, pet_ids, head_cursor)
    has_more_older = await _has_more_older(db, pet_ids, tail_cursor)

    return TimelineWindowResponse(
        groups=groups,
        total=total,
        limit=limit,
        prev_cursor=_encode_cursor(head) if has_more_newer else None,
        next_cursor=_encode_cursor(tail) if has_more_older else None,
        has_more_newer=has_more_newer,
        has_more_older=has_more_older,
        requested_anchor_month=requested_anchor_month,
        resolved_anchor_month=resolved_anchor_month,
        date_range=date_range,
    )


async def get_timeline_dates(
    db: AsyncSession,
    user_id: int,
    *,
    requested_pet_ids: list[int] | None,
) -> TimelineDatesResponse:
    pet_ids = await _resolve_accessible_pet_ids(db, user_id, requested_pet_ids)
    date_range = await _date_range(db, pet_ids)

    if not pet_ids:
        return TimelineDatesResponse(months=[], date_range=date_range)

    # `extract` is compiled to strftime on SQLite and EXTRACT() on Postgres,
    # so this works across both backends.
    year_expr = extract("year", Photo.taken_at)
    month_expr = extract("month", Photo.taken_at)

    stmt = (
        select(
            year_expr.label("y"),
            month_expr.label("m"),
            func.count().label("c"),
            func.max(Photo.taken_at).label("mx"),
        )
        .where(Photo.pet_id.in_(pet_ids))
        .group_by(year_expr, month_expr)
        .order_by(func.max(Photo.taken_at).desc())
    )
    result = await db.execute(stmt)
    months: list[DateDistributionItem] = []
    for y, m, c, _mx in result.all():
        key = f"{int(y):04d}-{int(m):02d}"
        months.append(
            DateDistributionItem(date=key, label=_month_label(key), count=int(c))
        )

    return TimelineDatesResponse(months=months, date_range=date_range)
