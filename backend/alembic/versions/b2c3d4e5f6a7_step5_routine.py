"""step5: add routines table + pet routine cycle/reminder fields

Revision ID: b2c3d4e5f6a7
Revises: a1b2c3d4e5f6
Create Date: 2026-04-17 10:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b2c3d4e5f6a7'
down_revision: Union[str, None] = 'a1b2c3d4e5f6'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1) Add routine cycle + reminder columns on pets
    op.add_column(
        'pets',
        sa.Column('bath_cycle_days', sa.Integer(), nullable=True),
    )
    op.add_column(
        'pets',
        sa.Column('nail_trim_cycle_days', sa.Integer(), nullable=True),
    )
    op.add_column(
        'pets',
        sa.Column('grooming_cycle_days', sa.Integer(), nullable=True),
    )
    for col in ('bath_reminder_enabled', 'nail_trim_reminder_enabled', 'grooming_reminder_enabled'):
        op.add_column(
            'pets',
            sa.Column(col, sa.Boolean(), nullable=False, server_default=sa.false()),
        )
        op.alter_column('pets', col, server_default=None)

    # 2) Create routines table
    op.create_table(
        'routines',
        sa.Column('id', sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column('pet_id', sa.BigInteger(), nullable=False),
        sa.Column('user_id', sa.BigInteger(), nullable=False),
        sa.Column(
            'routine_type',
            sa.Enum('BATH', 'NAIL_TRIM', 'GROOMING', name='routinetype'),
            nullable=False,
        ),
        sa.Column('performed_at', sa.Date(), nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['pet_id'], ['pets.id']),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(op.f('ix_routines_pet_id'), 'routines', ['pet_id'], unique=False)


def downgrade() -> None:
    op.drop_index(op.f('ix_routines_pet_id'), table_name='routines')
    op.drop_table('routines')
    op.execute('DROP TYPE IF EXISTS routinetype')

    op.drop_column('pets', 'grooming_reminder_enabled')
    op.drop_column('pets', 'nail_trim_reminder_enabled')
    op.drop_column('pets', 'bath_reminder_enabled')
    op.drop_column('pets', 'grooming_cycle_days')
    op.drop_column('pets', 'nail_trim_cycle_days')
    op.drop_column('pets', 'bath_cycle_days')
