"""avatar_url: store bucket-relative key instead of absolute URL

Revision ID: c9d0e1f2a3b4
Revises: b8c9d0e1f2a3
Create Date: 2026-05-26 00:00:00.000000

Avatars used to be persisted as absolute URLs
(``{PUBLIC_BASE_URL}/media/avatars/...``), so a domain / scheme change broke
every existing avatar (dead host). They now store the bucket-relative object
key (e.g. ``pets/8/170.jpg``) and the URL is composed at response time via
``app.services.storage.build_avatar_url`` — mirroring how photos store keys.

This migration rewrites existing ``users.avatar_url`` / ``pets.avatar_url``
rows from absolute URL → key. Idempotent: rows already in key form (no
scheme) are left untouched.
"""
from typing import Sequence, Union

from alembic import op

from app.config import settings


revision: str = "c9d0e1f2a3b4"
down_revision: Union[str, None] = "b8c9d0e1f2a3"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# Strip "<scheme>://<host>[:port]/media/avatars/" down to the bucket-relative
# key. The host is matched generically so it works regardless of which domain
# / IP was baked in at write time.
_URL_TO_KEY = "regexp_replace(avatar_url, '^https?://[^/]+/media/avatars/', '')"
_IS_ABSOLUTE = "avatar_url ~ '^https?://[^/]+/media/avatars/'"


def upgrade() -> None:
    for table in ("users", "pets"):
        op.execute(
            f"UPDATE {table} SET avatar_url = {_URL_TO_KEY} WHERE {_IS_ABSOLUTE}"
        )


def downgrade() -> None:
    # Rebuild absolute URLs from keys using the current PUBLIC_BASE_URL.
    prefix = f"{settings.PUBLIC_BASE_URL.rstrip('/')}/media/avatars/"
    for table in ("users", "pets"):
        op.execute(
            f"UPDATE {table} SET avatar_url = '{prefix}' || avatar_url "
            f"WHERE avatar_url IS NOT NULL AND avatar_url NOT LIKE 'http%'"
        )
