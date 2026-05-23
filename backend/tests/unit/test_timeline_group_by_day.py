"""Unit tests for the Optimization Step 2 day-level grouping helper.

Validates:
  * Same `taken_at` photos land in the same group.
  * Different days split into separate groups, in DESC stable order
    (newest day first).
  * Days without any photo never appear as empty placeholder groups.
  * `groups[].date` is the 10-char `YYYY-MM-DD` form (not `YYYY-MM`).
  * `groups[].label` follows the human-friendly Chinese `YYYY年M月D日`.
"""
from datetime import date, datetime

from app.schemas.photo import TimelinePhotoItem
from app.services.timeline import _group_by_day


def _item(day: date, photo_id: int) -> TimelinePhotoItem:
    return TimelinePhotoItem(
        id=photo_id,
        pet_id=1,
        pet_name="毛球",
        pet_type="cat",
        uploader_id=1,
        uploader_nickname=None,
        thumbnail_url="",
        thumbnail_sm_url="",
        taken_at=day,
        created_at=datetime(day.year, day.month, day.day, 10, 0, 0),
    )


def test_groups_collapse_to_one_per_day():
    # Three photos taken on the same day must produce ONE group with
    # three photos, not three day groups with one photo each.
    photos = [
        _item(date(2026, 1, 3), 30),
        _item(date(2026, 1, 3), 31),
        _item(date(2026, 1, 3), 32),
    ]
    groups = _group_by_day(photos)
    assert len(groups) == 1
    assert groups[0].date == "2026-01-03"
    assert groups[0].label == "2026年1月3日"
    assert [p.id for p in groups[0].photos] == [30, 31, 32]


def test_groups_split_per_distinct_day():
    # Newer-first input → groups should follow the same order.
    photos = [
        _item(date(2026, 1, 3), 30),
        _item(date(2026, 1, 1), 10),
        _item(date(2025, 12, 31), 9),
    ]
    groups = _group_by_day(photos)
    assert [g.date for g in groups] == [
        "2026-01-03",
        "2026-01-01",
        "2025-12-31",
    ]
    assert [g.label for g in groups] == [
        "2026年1月3日",
        "2026年1月1日",
        "2025年12月31日",
    ]


def test_days_without_photos_are_omitted():
    # 2026-01-02 has no photo and must not appear as an empty group
    # between the two surrounding day buckets.
    photos = [
        _item(date(2026, 1, 3), 30),
        _item(date(2026, 1, 1), 10),
    ]
    groups = _group_by_day(photos)
    assert [g.date for g in groups] == ["2026-01-03", "2026-01-01"]
    assert all(len(g.photos) > 0 for g in groups)


def test_date_format_is_full_iso_not_month_prefix():
    # Regression guard against accidentally falling back to the legacy
    # month-only key — every group date must be 10 chars (YYYY-MM-DD).
    photos = [
        _item(date(2026, 5, 9), 1),
        _item(date(2026, 5, 1), 2),
    ]
    groups = _group_by_day(photos)
    for g in groups:
        assert len(g.date) == 10, g.date
        assert g.date.count("-") == 2


def test_empty_input_yields_empty_groups():
    assert _group_by_day([]) == []
