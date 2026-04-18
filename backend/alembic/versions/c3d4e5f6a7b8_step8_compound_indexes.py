"""step8: compound indexes for timeline / list / status queries

Revision ID: c3d4e5f6a7b8
Revises: b2c3d4e5f6a7
Create Date: 2026-04-18 18:00:00.000000

Adds compound indexes per §1.1 rule 2 of step8-integration-polish.md to
avoid filesort on main list / timeline / status queries once row counts grow.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'c3d4e5f6a7b8'
down_revision: Union[str, None] = 'b2c3d4e5f6a7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


# (index_name, table, ordered_column_expressions)
_INDEXES: list[tuple[str, str, list[str]]] = [
    (
        'ix_photos_pet_taken_created_id',
        'photos',
        ['pet_id', 'taken_at DESC', 'created_at DESC', 'id DESC'],
    ),
    (
        'ix_weights_pet_recorded_created_id',
        'weights',
        ['pet_id', 'recorded_at DESC', 'created_at DESC', 'id DESC'],
    ),
    (
        'ix_dewormings_pet_type_dewormed_id',
        'dewormings',
        ['pet_id', 'deworming_type', 'dewormed_at DESC', 'id DESC'],
    ),
    (
        'ix_vaccinations_pet_vaccinated_created_id',
        'vaccinations',
        ['pet_id', 'vaccinated_at DESC', 'created_at DESC', 'id DESC'],
    ),
    (
        'ix_routines_pet_type_performed_id',
        'routines',
        ['pet_id', 'routine_type', 'performed_at DESC', 'id DESC'],
    ),
    (
        'ix_pet_members_user_id',
        'pet_members',
        ['user_id'],
    ),
]


def upgrade() -> None:
    for name, table, cols in _INDEXES:
        op.create_index(name, table, [sa.text(c) for c in cols], unique=False)


def downgrade() -> None:
    for name, table, _cols in reversed(_INDEXES):
        op.drop_index(name, table_name=table)
