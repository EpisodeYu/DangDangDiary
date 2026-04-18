"""Production safety guard for application startup.

Per §1.1 rule 6 / Step 8 Chunk B-4:
  * `DEBUG=True` → the function returns immediately with no log output.
    Development and pytest environments must stay completely silent.
  * `DEBUG=False` → any critical secret still holding its `.env.example`
    default value triggers a `RuntimeError` that names every offending
    field. A weak `JWT_SECRET_KEY` (short / clearly non-random) only
    emits a single warning and does not block startup.
"""
from __future__ import annotations

import logging
import re
from typing import Iterable

logger = logging.getLogger(__name__)

# Default / placeholder values that must never appear in a production
# deployment. Kept in sync with `app/config.py` and `.env.example`.
_DEFAULT_VALUES: dict[str, tuple[object, ...]] = {
    "JWT_SECRET_KEY": ("your-secret-key-change-in-production",),
    "MINIO_SECRET_KEY": ("minioadmin123", "minioadmin"),
    "ALIYUN_ACCESS_KEY_ID": ("",),
    "ALIYUN_ACCESS_KEY_SECRET": ("",),
    "PUBLIC_BASE_URL": ("http://YOUR_SERVER_IP",),
}

_MIN_JWT_KEY_LENGTH = 32

# Obviously weak patterns worth calling out to the operator. Matching is
# case-insensitive and anchored at word boundaries.
_WEAK_JWT_TOKENS = (
    "secret",
    "password",
    "changeme",
    "dangdang",
    "dev",
    "test",
    "example",
)


class ProductionSafetyError(RuntimeError):
    """Raised when startup detects insecure configuration in prod mode."""

    def __init__(self, failed_fields: Iterable[str]):
        self.failed_fields = list(failed_fields)
        pretty = ", ".join(self.failed_fields)
        super().__init__(
            "Production safety check failed; the following settings still use "
            f"their default / placeholder values: {pretty}. "
            "Please override them via .env before running with DEBUG=False."
        )


def assert_production_safe(settings) -> None:
    """Block unsafe production startup. Silent in DEBUG mode.

    Parameters
    ----------
    settings:
        The `Settings` instance from `app.config`.

    Raises
    ------
    ProductionSafetyError
        Sub-class of `RuntimeError`. Raised only when `DEBUG=False` and at
        least one critical field is still a placeholder.
    """
    # Q4 decision: zero-friction dev/test mode — produce no logs at all.
    if getattr(settings, "DEBUG", False):
        return

    failed: list[str] = []
    for field, defaults in _DEFAULT_VALUES.items():
        current = getattr(settings, field, None)
        if current in defaults:
            failed.append(field)

    if failed:
        raise ProductionSafetyError(failed)

    _warn_if_jwt_key_weak(getattr(settings, "JWT_SECRET_KEY", ""))


def _warn_if_jwt_key_weak(key: str) -> None:
    if not key:
        return
    if len(key) < _MIN_JWT_KEY_LENGTH:
        logger.warning(
            "JWT_SECRET_KEY is shorter than %d characters (current=%d); "
            "consider using `python -c 'import secrets; print(secrets.token_urlsafe(48))'`.",
            _MIN_JWT_KEY_LENGTH,
            len(key),
        )
        return

    lowered = key.lower()
    for token in _WEAK_JWT_TOKENS:
        if re.search(rf"\b{re.escape(token)}\b", lowered):
            logger.warning(
                "JWT_SECRET_KEY contains a predictable word (%r); "
                "use a cryptographically random string in production.",
                token,
            )
            return
