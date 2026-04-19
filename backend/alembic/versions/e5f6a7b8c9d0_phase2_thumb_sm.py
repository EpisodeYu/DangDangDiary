"""phase2: per-tile small thumbnail key for photos

Revision ID: e5f6a7b8c9d0
Revises: d4e5f6a7b8c9
Create Date: 2026-04-19 21:30:00.000000

Adds `photos.thumbnail_sm_key` so we can serve a ~200 px thumbnail to the
timeline calendar grid alongside the existing ~400 px detail thumbnail. The
column is nullable so existing rows keep working — the API falls back to
`thumbnail_key` when this is NULL, and a separate backfill task can fill it
in opportunistically.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'e5f6a7b8c9d0'
down_revision: Union[str, None] = 'd4e5f6a7b8c9'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.add_column(
        'photos',
        sa.Column('thumbnail_sm_key', sa.String(length=500), nullable=True),
    )


def downgrade() -> None:
    op.drop_column('photos', 'thumbnail_sm_key')
