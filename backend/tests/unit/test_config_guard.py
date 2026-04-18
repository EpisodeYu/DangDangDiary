"""Unit tests for `app.utils.production_check` (Step 8 Chunk B-4 / §1.1 rule 6).

Covers:
  * DEBUG=True + all defaults → returns silently, zero log records.
  * DEBUG=False + default JWT_SECRET_KEY → RuntimeError, message names the field.
  * DEBUG=False + default PUBLIC_BASE_URL → RuntimeError, message names the field.
  * DEBUG=False + default MinIO / Aliyun keys → RuntimeError lists every offender.
  * DEBUG=False + strong overrides → returns quietly (no warning/error log).
  * DEBUG=False + a random-looking but short JWT key → warning, no raise.
  * DEBUG=False + a key that contains a dictionary-like token → warning, no raise.
"""
from __future__ import annotations

import logging
from types import SimpleNamespace

import pytest

from app.utils.production_check import (
    ProductionSafetyError,
    assert_production_safe,
)


# Values that come verbatim from `app/config.py` / `.env.example`.
_DEFAULTS = {
    "DEBUG": True,
    "JWT_SECRET_KEY": "your-secret-key-change-in-production",
    "MINIO_SECRET_KEY": "minioadmin123",
    "ALIYUN_ACCESS_KEY_ID": "",
    "ALIYUN_ACCESS_KEY_SECRET": "",
    "PUBLIC_BASE_URL": "http://YOUR_SERVER_IP",
}


def _make_settings(**overrides) -> SimpleNamespace:
    data = {**_DEFAULTS, **overrides}
    return SimpleNamespace(**data)


def _strong_settings(**overrides) -> SimpleNamespace:
    # All fields carry a safe-looking prod-ready value. Tests can override
    # just the field under examination.
    base = {
        "DEBUG": False,
        "JWT_SECRET_KEY": "0b8f3d9a7c1e4f52a76d8b09e3f7c21ab5c14e8f6a02d49b",
        "MINIO_SECRET_KEY": "prod-minio-key-42",
        "ALIYUN_ACCESS_KEY_ID": "LTAI-prod-id",
        "ALIYUN_ACCESS_KEY_SECRET": "prod-secret-abc123",
        "PUBLIC_BASE_URL": "https://dangdang.example.com",
    }
    base.update(overrides)
    return _make_settings(**base)


# ---------------- DEBUG=True: completely silent ----------------

def test_debug_true_with_all_defaults_returns_silently(caplog):
    settings = _make_settings(DEBUG=True)  # all fields defaulted
    with caplog.at_level(logging.DEBUG, logger="app.utils.production_check"):
        assert_production_safe(settings)
    # Q4 decision: zero log output in dev/test so pytest stays clean.
    assert caplog.records == [], (
        f"DEBUG=True must produce no log records; got: {caplog.records!r}"
    )


# ---------------- DEBUG=False: hard-fail on defaults ----------------

def test_default_jwt_secret_key_raises():
    settings = _strong_settings(
        JWT_SECRET_KEY="your-secret-key-change-in-production",
    )
    with pytest.raises(ProductionSafetyError) as exc:
        assert_production_safe(settings)
    assert "JWT_SECRET_KEY" in str(exc.value)
    assert exc.value.failed_fields == ["JWT_SECRET_KEY"]


def test_default_public_base_url_raises():
    settings = _strong_settings(PUBLIC_BASE_URL="http://YOUR_SERVER_IP")
    with pytest.raises(ProductionSafetyError) as exc:
        assert_production_safe(settings)
    assert "PUBLIC_BASE_URL" in str(exc.value)
    assert exc.value.failed_fields == ["PUBLIC_BASE_URL"]


def test_default_minio_and_aliyun_credentials_raise():
    settings = _strong_settings(
        MINIO_SECRET_KEY="minioadmin123",
        ALIYUN_ACCESS_KEY_ID="",
        ALIYUN_ACCESS_KEY_SECRET="",
    )
    with pytest.raises(ProductionSafetyError) as exc:
        assert_production_safe(settings)
    for field in ("MINIO_SECRET_KEY", "ALIYUN_ACCESS_KEY_ID", "ALIYUN_ACCESS_KEY_SECRET"):
        assert field in str(exc.value)
        assert field in exc.value.failed_fields


def test_full_default_settings_report_every_field():
    settings = _make_settings(DEBUG=False)  # every secret still defaulted
    with pytest.raises(ProductionSafetyError) as exc:
        assert_production_safe(settings)
    expected = {
        "JWT_SECRET_KEY",
        "MINIO_SECRET_KEY",
        "ALIYUN_ACCESS_KEY_ID",
        "ALIYUN_ACCESS_KEY_SECRET",
        "PUBLIC_BASE_URL",
    }
    assert set(exc.value.failed_fields) == expected


# ---------------- DEBUG=False: strong overrides pass cleanly ----------------

def test_strong_settings_pass_without_warnings(caplog):
    settings = _strong_settings()
    with caplog.at_level(logging.WARNING, logger="app.utils.production_check"):
        assert_production_safe(settings)
    assert caplog.records == []


# ---------------- DEBUG=False: weak-but-overridden key → warning only ----------------

def test_short_jwt_key_emits_warning_but_does_not_raise(caplog):
    settings = _strong_settings(JWT_SECRET_KEY="abc123")  # clearly too short
    with caplog.at_level(logging.WARNING, logger="app.utils.production_check"):
        assert_production_safe(settings)
    assert any("shorter" in rec.message for rec in caplog.records)


def test_dictionary_word_in_jwt_key_emits_warning_but_does_not_raise(caplog):
    # Long enough to pass the length gate, but contains a predictable token.
    weak = "my-dev-secret-padded-" + "x" * 40
    settings = _strong_settings(JWT_SECRET_KEY=weak)
    with caplog.at_level(logging.WARNING, logger="app.utils.production_check"):
        assert_production_safe(settings)
    assert any("predictable" in rec.message for rec in caplog.records)
