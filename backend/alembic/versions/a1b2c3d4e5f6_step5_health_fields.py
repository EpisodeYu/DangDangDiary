"""step5: add deworming COMBINED + pet reminder fields

Revision ID: a1b2c3d4e5f6
Revises: fc219291de06
Create Date: 2026-04-16 22:50:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'a1b2c3d4e5f6'
down_revision: Union[str, None] = 'fc219291de06'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1) Extend dewormingtype enum with COMBINED (Postgres)
    op.execute("ALTER TYPE dewormingtype ADD VALUE IF NOT EXISTS 'COMBINED'")

    # 2) Add columns on pets
    op.add_column(
        'pets',
        sa.Column('combined_deworming_cycle_days', sa.Integer(), nullable=True),
    )
    op.add_column(
        'pets',
        sa.Column(
            'internal_reminder_enabled',
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )
    op.add_column(
        'pets',
        sa.Column(
            'external_reminder_enabled',
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )
    op.add_column(
        'pets',
        sa.Column(
            'combined_reminder_enabled',
            sa.Boolean(),
            nullable=False,
            server_default=sa.false(),
        ),
    )

    # Drop server defaults so application controls values afterwards
    op.alter_column('pets', 'internal_reminder_enabled', server_default=None)
    op.alter_column('pets', 'external_reminder_enabled', server_default=None)
    op.alter_column('pets', 'combined_reminder_enabled', server_default=None)


def downgrade() -> None:
    op.drop_column('pets', 'combined_reminder_enabled')
    op.drop_column('pets', 'external_reminder_enabled')
    op.drop_column('pets', 'internal_reminder_enabled')
    op.drop_column('pets', 'combined_deworming_cycle_days')
    # Note: removing a value from a Postgres enum is non-trivial; leaving 'COMBINED' in place.
