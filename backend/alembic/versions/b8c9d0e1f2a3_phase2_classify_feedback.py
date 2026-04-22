"""phase2 step3 option A: classify correction feedback log

Revision ID: b8c9d0e1f2a3
Revises: a7b8c9d0e1f2
Create Date: 2026-04-22 00:00:00.000000

Adds ``classify_feedbacks`` — a structured log of every chip override
the user made on the record screen. Enables future decision-rule
tuning and spotting reliably-confused pet pairs.

Note: this migration does **not** touch ``pet_photo_embeddings``.
The per-source boost and near-duplicate collapse are pure service-layer
changes (see ``app/services/pet_centroid.py``) and need no schema
change.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = "b8c9d0e1f2a3"
down_revision: Union[str, None] = "a7b8c9d0e1f2"
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.create_table(
        "classify_feedbacks",
        sa.Column("id", sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.BigInteger(), nullable=False),
        sa.Column("from_pet_id", sa.BigInteger(), nullable=True),
        sa.Column("to_pet_id", sa.BigInteger(), nullable=False),
        sa.Column("photo_id", sa.BigInteger(), nullable=True),
        sa.Column("top1_similarity", sa.Float(), nullable=True),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(["user_id"], ["users.id"]),
        sa.ForeignKeyConstraint(
            ["from_pet_id"], ["pets.id"], ondelete="SET NULL",
        ),
        sa.ForeignKeyConstraint(
            ["to_pet_id"], ["pets.id"], ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["photo_id"], ["photos.id"], ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("id"),
    )
    op.create_index(
        "ix_classify_feedbacks_user_id", "classify_feedbacks", ["user_id"],
    )
    op.create_index(
        "ix_classify_feedbacks_from_pet_id",
        "classify_feedbacks",
        ["from_pet_id"],
    )
    op.create_index(
        "ix_classify_feedbacks_to_pet_id",
        "classify_feedbacks",
        ["to_pet_id"],
    )
    op.create_index(
        "ix_classify_feedbacks_created_at",
        "classify_feedbacks",
        ["created_at"],
    )


def downgrade() -> None:
    op.drop_index(
        "ix_classify_feedbacks_created_at", table_name="classify_feedbacks",
    )
    op.drop_index(
        "ix_classify_feedbacks_to_pet_id", table_name="classify_feedbacks",
    )
    op.drop_index(
        "ix_classify_feedbacks_from_pet_id", table_name="classify_feedbacks",
    )
    op.drop_index(
        "ix_classify_feedbacks_user_id", table_name="classify_feedbacks",
    )
    op.drop_table("classify_feedbacks")
