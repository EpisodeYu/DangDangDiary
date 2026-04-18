"""Unit tests for `app.utils.security` (Chunk A-3 / §2.2).

Covers:
  * create/decode access token round-trip
  * create/decode refresh token round-trip
  * expired token → None
  * tampered payload → None
  * wrong algorithm → None
  * type distinction (access vs refresh)
"""
from datetime import datetime, timedelta, timezone

import pytest
from jose import jwt

from app.config import settings
from app.utils.security import (
    create_access_token,
    create_refresh_token,
    decode_token,
)


def test_access_token_roundtrip():
    token = create_access_token(42)
    payload = decode_token(token)
    assert payload is not None
    assert payload["sub"] == "42"
    assert payload["type"] == "access"
    assert "exp" in payload


def test_refresh_token_roundtrip():
    token = create_refresh_token(99)
    payload = decode_token(token)
    assert payload is not None
    assert payload["sub"] == "99"
    assert payload["type"] == "refresh"


def test_access_and_refresh_have_distinct_types():
    access = decode_token(create_access_token(1))
    refresh = decode_token(create_refresh_token(1))
    assert access is not None and refresh is not None
    assert access["type"] != refresh["type"]


def test_expired_token_returns_none():
    payload = {
        "sub": "1",
        "exp": datetime.now(timezone.utc) - timedelta(seconds=5),
        "type": "access",
    }
    expired = jwt.encode(
        payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM
    )
    assert decode_token(expired) is None


def test_tampered_payload_returns_none():
    token = create_access_token(7)
    # Flip the last character of the signature segment.
    header, body, signature = token.split(".")
    tampered_sig = signature[:-1] + ("A" if signature[-1] != "A" else "B")
    tampered = f"{header}.{body}.{tampered_sig}"
    assert decode_token(tampered) is None


def test_wrong_algorithm_returns_none():
    # Forge a token signed with a different algorithm than the service accepts.
    payload = {
        "sub": "1",
        "exp": datetime.now(timezone.utc) + timedelta(hours=1),
        "type": "access",
    }
    wrong_alg = "HS512" if settings.JWT_ALGORITHM != "HS512" else "HS384"
    forged = jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=wrong_alg)
    assert decode_token(forged) is None


def test_wrong_secret_returns_none():
    payload = {
        "sub": "1",
        "exp": datetime.now(timezone.utc) + timedelta(hours=1),
        "type": "access",
    }
    forged = jwt.encode(payload, "not-the-real-secret", algorithm=settings.JWT_ALGORITHM)
    assert decode_token(forged) is None
