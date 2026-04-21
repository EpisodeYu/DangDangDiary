"""phase2 step3: pet photo embeddings for auto-assign

Revision ID: a7b8c9d0e1f2
Revises: f6a7b8c9d0e1
Create Date: 2026-04-21 12:00:00.000000

Adds `pet_photo_embeddings` for the DashScope multi-modal embedding
based classify flow (docs/phase2-step3-photo-auto-assign.md §3-§4).

The vector dimension (1152) matches
``settings.DASHSCOPE_EMBEDDING_DIMENSION`` which defaults to the
Singapore-region ``tongyi-embedding-vision-plus`` output. Bumping the
setting requires a fresh migration — the column's length is baked in.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from pgvector.sqlalchemy import Vector


revision: str = 'a7b8c9d0e1f2'
down_revision: Union[str, None] = 'f6a7b8c9d0e1'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


_EMBEDDING_DIM = 1152


def upgrade() -> None:
    bind = op.get_bind()

    if bind.dialect.name == "postgresql":
        # pgvector ships with the `pgvector/pgvector:pg16` image we now
        # use in docker-compose. The extension is idempotent.
        op.execute("CREATE EXTENSION IF NOT EXISTS vector")

    op.create_table(
        'pet_photo_embeddings',
        sa.Column('id', sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column('pet_id', sa.BigInteger(), nullable=False),
        sa.Column('photo_id', sa.BigInteger(), nullable=True),
        sa.Column('embedding', Vector(_EMBEDDING_DIM), nullable=False),
        sa.Column(
            'source',
            sa.Enum(
                'pet_avatar', 'user_uploaded', 'user_corrected',
                name='embeddingsource',
            ),
            nullable=False,
        ),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['pet_id'], ['pets.id']),
        sa.ForeignKeyConstraint(['photo_id'], ['photos.id'], ondelete='SET NULL'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index(
        'ix_pet_photo_embeddings_pet_id',
        'pet_photo_embeddings',
        ['pet_id'],
    )
    op.create_index(
        'ix_pet_photo_embeddings_created_at',
        'pet_photo_embeddings',
        ['created_at'],
    )

    if bind.dialect.name == "postgresql":
        # IVFFlat tuning: lists ≈ sqrt(N_rows). With an empty table the
        # index is effectively a no-op; operations should REINDEX with
        # a tuned `lists` once real data is in (see runbook in §4 of
        # the step-3 doc).
        op.execute(
            "CREATE INDEX ix_pet_photo_embeddings_cosine "
            "ON pet_photo_embeddings USING ivfflat "
            "(embedding vector_cosine_ops) WITH (lists = 50)"
        )


def downgrade() -> None:
    bind = op.get_bind()

    if bind.dialect.name == "postgresql":
        op.execute("DROP INDEX IF EXISTS ix_pet_photo_embeddings_cosine")
    op.drop_index(
        'ix_pet_photo_embeddings_created_at',
        table_name='pet_photo_embeddings',
    )
    op.drop_index(
        'ix_pet_photo_embeddings_pet_id',
        table_name='pet_photo_embeddings',
    )
    op.drop_table('pet_photo_embeddings')

    if bind.dialect.name == "postgresql":
        op.execute('DROP TYPE IF EXISTS embeddingsource')
    # Intentionally no DROP EXTENSION — other Phase-2+ features may
    # share the vector extension.
