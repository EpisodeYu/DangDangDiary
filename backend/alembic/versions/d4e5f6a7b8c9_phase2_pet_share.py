"""phase2 step1: pet sharing (member roles + pet_share_codes)

Revision ID: d4e5f6a7b8c9
Revises: c3d4e5f6a7b8
Create Date: 2026-04-18 22:00:00.000000

- Migrate `memberrole` enum from {OWNER, MEMBER} to {OWNER, EDITOR, VIEWER}
  by rebuilding the type. Existing rows with role='MEMBER' become 'VIEWER'.
- Create `pet_share_codes` for time-limited share invitations.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'd4e5f6a7b8c9'
down_revision: Union[str, None] = 'c3d4e5f6a7b8'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # 1) Create the new pet_share_codes table.
    op.create_table(
        'pet_share_codes',
        sa.Column('id', sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column('pet_id', sa.BigInteger(), nullable=False),
        sa.Column('code', sa.String(length=16), nullable=False),
        sa.Column('created_by', sa.BigInteger(), nullable=False),
        sa.Column('expires_at', sa.DateTime(), nullable=False),
        sa.Column('used_at', sa.DateTime(), nullable=True),
        sa.Column('used_by_user_id', sa.BigInteger(), nullable=True),
        sa.Column('revoked_at', sa.DateTime(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['pet_id'], ['pets.id']),
        sa.ForeignKeyConstraint(['created_by'], ['users.id']),
        sa.ForeignKeyConstraint(['used_by_user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('code', name='uq_pet_share_codes_code'),
    )
    op.create_index('ix_pet_share_codes_pet_id', 'pet_share_codes', ['pet_id'])
    op.create_index(
        'ix_pet_share_codes_pet_active',
        'pet_share_codes',
        ['pet_id', 'revoked_at', 'used_at', 'expires_at'],
    )

    # 2) Rebuild the memberrole enum to drop MEMBER and add EDITOR/VIEWER.
    # Postgres enums cannot drop values in-place, so rename → recreate → cast.
    bind = op.get_bind()
    if bind.dialect.name == 'postgresql':
        # Migrate data first while the old type still accepts 'MEMBER'.
        op.execute("UPDATE pet_members SET role = 'VIEWER' WHERE role = 'MEMBER'")

        op.execute("ALTER TYPE memberrole RENAME TO memberrole_old")
        op.execute("CREATE TYPE memberrole AS ENUM ('OWNER', 'EDITOR', 'VIEWER')")
        op.execute(
            "ALTER TABLE pet_members "
            "ALTER COLUMN role TYPE memberrole USING role::text::memberrole"
        )
        op.execute("DROP TYPE memberrole_old")
    else:
        # SQLite / others: enum is just a CHECK constraint; rewrite values only.
        op.execute("UPDATE pet_members SET role = 'VIEWER' WHERE role = 'MEMBER'")


def downgrade() -> None:
    bind = op.get_bind()
    if bind.dialect.name == 'postgresql':
        op.execute("ALTER TYPE memberrole RENAME TO memberrole_new")
        op.execute("CREATE TYPE memberrole AS ENUM ('OWNER', 'MEMBER')")
        op.execute(
            "UPDATE pet_members SET role = 'MEMBER' "
            "WHERE role IN ('EDITOR', 'VIEWER')"
        )
        op.execute(
            "ALTER TABLE pet_members "
            "ALTER COLUMN role TYPE memberrole USING role::text::memberrole"
        )
        op.execute("DROP TYPE memberrole_new")
    else:
        op.execute(
            "UPDATE pet_members SET role = 'MEMBER' "
            "WHERE role IN ('EDITOR', 'VIEWER')"
        )

    op.drop_index('ix_pet_share_codes_pet_active', table_name='pet_share_codes')
    op.drop_index('ix_pet_share_codes_pet_id', table_name='pet_share_codes')
    op.drop_table('pet_share_codes')
