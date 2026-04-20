"""Unit tests for the pure normalisation helpers in ``services.voice_intake``.

These exercise the risky parts of voice intake (date parsing, enum
guarding, pet-name resolution) without touching STT / LLM / MinIO.
"""
from datetime import date, timedelta

import app.models  # noqa: F401 register ORM
from app.schemas.voice_intake import VoiceIntakeDraft
from app.services import voice_intake as vi


# ----------------------------- dates


def test_parse_date_today_yesterday():
    today = date(2026, 4, 20)
    assert vi._parse_date("today", today=today) == today
    assert vi._parse_date("TODAY", today=today) == today
    assert vi._parse_date("yesterday", today=today) == today - timedelta(days=1)


def test_parse_date_n_days_ago():
    today = date(2026, 4, 20)
    assert vi._parse_date("N_days_ago:3", today=today) == date(2026, 4, 17)
    assert vi._parse_date("n_days_ago:0", today=today) == today
    assert vi._parse_date("N_days_ago:9999", today=today) is None


def test_parse_date_iso_and_future_guard():
    today = date(2026, 4, 20)
    assert vi._parse_date("2026-04-18", today=today) == date(2026, 4, 18)
    # Future dates are rejected — silently drop so they become missing.
    assert vi._parse_date("2030-01-01", today=today) is None


def test_parse_date_rejects_junk():
    today = date(2026, 4, 20)
    assert vi._parse_date(None, today=today) is None
    assert vi._parse_date("", today=today) is None
    assert vi._parse_date("明天", today=today) is None
    assert vi._parse_date(42, today=today) is None
    assert vi._parse_date("2026-13-01", today=today) is None


# ----------------------------- enums


def test_parse_deworming_type():
    assert vi._parse_deworming_type("internal") == "internal"
    assert vi._parse_deworming_type("  Combined ") == "combined"
    assert vi._parse_deworming_type("unknown") is None
    assert vi._parse_deworming_type(None) is None


def test_parse_routine_type():
    assert vi._parse_routine_type("bath") == "bath"
    assert vi._parse_routine_type("nail_trim") == "nail_trim"
    # walk / feed are not supported in Phase 2 step 2 (see doc §5).
    assert vi._parse_routine_type("walk") is None


def test_parse_weight_kg_range():
    assert vi._parse_weight_kg(6.2) == 6.2
    assert vi._parse_weight_kg("5.5") == 5.5
    assert vi._parse_weight_kg(0) is None
    assert vi._parse_weight_kg(-1) is None
    assert vi._parse_weight_kg(500) is None
    assert vi._parse_weight_kg("abc") is None


def test_clamp_confidence():
    assert vi._clamp_confidence(85) == 85
    assert vi._clamp_confidence(-5) == 0
    assert vi._clamp_confidence(1000) == 100
    assert vi._clamp_confidence(None) == 0
    assert vi._clamp_confidence("x") == 0


# ------------------------- normalize_draft / missing fields


def test_normalize_draft_happy_path():
    today = date(2026, 4, 20)
    llm = {
        "intent": "deworming",
        "pet_name": "咪咪",
        "dewormed_at": "today",
        "deworming_type": "internal",
        "vaccine_name": None,
        "vaccinated_at": None,
        "weight_kg": None,
        "weighed_at": None,
        "routine_type": None,
        "routine_at": None,
        "note": "  ",
        "confidence": 88,
    }
    draft, intent, conf, note = vi._normalize_draft(
        llm, pet_id=3, pet_display_name="咪咪", today=today,
    )
    assert intent == "deworming"
    assert conf == 88
    assert note is None
    assert draft.pet_id == 3
    assert draft.pet_name == "咪咪"
    assert draft.deworming_type == "internal"
    assert draft.dewormed_at == today


def test_normalize_draft_unknown_collapses():
    today = date.today()
    llm = {"intent": "bogus", "confidence": "999"}
    draft, intent, conf, _note = vi._normalize_draft(
        llm, pet_id=None, pet_display_name=None, today=today,
    )
    assert intent == "unknown"
    assert conf == 100
    assert draft.pet_id is None


def test_compute_missing_fields_deworming():
    draft = VoiceIntakeDraft(pet_id=1, dewormed_at=date(2026, 4, 20))
    missing = vi._compute_missing_fields("deworming", draft)
    assert missing == ["deworming_type"]


def test_compute_missing_fields_weight_all_missing():
    draft = VoiceIntakeDraft()
    missing = vi._compute_missing_fields("weight", draft)
    assert set(missing) == {"pet_id", "weight_kg", "weighed_at"}


def test_compute_missing_fields_unknown_intent_empty():
    draft = VoiceIntakeDraft()
    assert vi._compute_missing_fields("unknown", draft) == []


# ------------------------- pet resolution (closed set)


class _FakePet:
    def __init__(self, pid, name):
        self.id = pid
        self.name = name


def test_resolve_pet_closed_set_exact_match():
    pets = [_FakePet(1, "咪咪"), _FakePet(2, "橘子")]
    pid, name = vi._resolve_pet_from_closed_set(
        pets, llm_pet_name="咪咪", default_pet_id=None,
    )
    assert pid == 1 and name == "咪咪"


def test_resolve_pet_closed_set_case_insensitive():
    pets = [_FakePet(1, "Luna")]
    pid, name = vi._resolve_pet_from_closed_set(
        pets, llm_pet_name="LUNA", default_pet_id=None,
    )
    assert pid == 1 and name == "Luna"


def test_resolve_pet_closed_set_unknown_name_no_fallback_without_default():
    # LLM went off-script (shouldn't happen, but we must handle it):
    # we refuse to guess — better missing than wrong.
    pets = [_FakePet(1, "咪咪"), _FakePet(2, "橘子")]
    pid, _ = vi._resolve_pet_from_closed_set(
        pets, llm_pet_name="Tom", default_pet_id=None,
    )
    assert pid is None


def test_resolve_pet_closed_set_falls_back_to_default_when_llm_silent():
    pets = [_FakePet(1, "咪咪"), _FakePet(2, "橘子")]
    pid, name = vi._resolve_pet_from_closed_set(
        pets, llm_pet_name=None, default_pet_id=2,
    )
    assert pid == 2 and name == "橘子"


def test_resolve_pet_closed_set_empty_pets():
    pid, _ = vi._resolve_pet_from_closed_set(
        [], llm_pet_name="咪咪", default_pet_id=None,
    )
    assert pid is None


# ------------------------- LLM prompt builder


def test_llm_user_msg_with_pet_list_included():
    from app.services import llm as llm_mod
    msg = llm_mod._build_user_message(
        "今天给咪咪做了驱虫",
        known_pet_names=["咪咪", "橘子"],
        default_pet_name="咪咪",
    )
    assert "「咪咪」" in msg
    assert "「橘子」" in msg
    assert "默认选中的宠物" in msg
    assert "今天给咪咪做了驱虫" in msg


def test_llm_user_msg_without_pet_list():
    from app.services import llm as llm_mod
    msg = llm_mod._build_user_message(
        "今天好开心", known_pet_names=[], default_pet_name=None,
    )
    assert "暂无宠物档案" in msg
