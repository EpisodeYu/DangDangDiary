"""Unit tests for timeline cursor helpers (Chunk A-3 / §2.2).

Covers:
  * `_encode_cursor` / `_decode_cursor` round-trip for a range of dates.
  * `_decode_cursor` rejects non-base64 / missing fields / bad dates with
    `AppException(400, INVALID_CURSOR)`.
"""
from datetime import date, datetime
from types import SimpleNamespace

import base64
import json

import pytest

from app.exceptions import AppException
from app.services.timeline import _decode_cursor, _encode_cursor


def _photo_stub(taken_at: date, created_at: datetime, photo_id: int):
    return SimpleNamespace(taken_at=taken_at, created_at=created_at, id=photo_id)


@pytest.mark.parametrize(
    "taken_at, created_at, photo_id",
    [
        (date(2024, 1, 1), datetime(2024, 1, 1, 12, 0, 0), 1),
        (date(2024, 6, 15), datetime(2024, 6, 15, 23, 59, 59, 123456), 42),
        (date(2020, 12, 31), datetime(2020, 12, 31, 0, 0, 0), 999999),
        (date(1999, 2, 28), datetime(1999, 2, 28, 10, 30, 45, 500000), 7),
    ],
)
def test_cursor_roundtrip(taken_at, created_at, photo_id):
    photo = _photo_stub(taken_at, created_at, photo_id)
    encoded = _encode_cursor(photo)

    cursor = _decode_cursor(encoded)
    assert cursor.taken_at == taken_at
    assert cursor.created_at == created_at
    assert cursor.id == photo_id


def test_decode_cursor_rejects_non_base64():
    with pytest.raises(AppException) as ei:
        _decode_cursor("!!!not-base64!!!")
    assert ei.value.status_code == 400
    assert ei.value.code == "INVALID_CURSOR"


def test_decode_cursor_rejects_missing_fields():
    raw = json.dumps({"taken_at": "2024-01-01"}).encode("utf-8")
    encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    with pytest.raises(AppException) as ei:
        _decode_cursor(encoded)
    assert ei.value.status_code == 400
    assert ei.value.code == "INVALID_CURSOR"


def test_decode_cursor_rejects_invalid_date():
    raw = json.dumps(
        {
            "taken_at": "not-a-date",
            "created_at": "2024-01-01T00:00:00",
            "id": 1,
        }
    ).encode("utf-8")
    encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    with pytest.raises(AppException) as ei:
        _decode_cursor(encoded)
    assert ei.value.status_code == 400
    assert ei.value.code == "INVALID_CURSOR"


def test_decode_cursor_rejects_invalid_datetime():
    raw = json.dumps(
        {
            "taken_at": "2024-01-01",
            "created_at": "not-a-datetime",
            "id": 1,
        }
    ).encode("utf-8")
    encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    with pytest.raises(AppException) as ei:
        _decode_cursor(encoded)
    assert ei.value.code == "INVALID_CURSOR"


def test_decode_cursor_rejects_non_integer_id():
    raw = json.dumps(
        {
            "taken_at": "2024-01-01",
            "created_at": "2024-01-01T00:00:00",
            "id": "abc",
        }
    ).encode("utf-8")
    encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    with pytest.raises(AppException) as ei:
        _decode_cursor(encoded)
    assert ei.value.code == "INVALID_CURSOR"


def test_decode_cursor_rejects_non_json_payload():
    raw = b"not json at all"
    encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")

    with pytest.raises(AppException) as ei:
        _decode_cursor(encoded)
    assert ei.value.code == "INVALID_CURSOR"
