"""phase2 step2: voice intake logs

Revision ID: f6a7b8c9d0e1
Revises: e5f6a7b8c9d0
Create Date: 2026-04-20 10:00:00.000000

Adds `voice_intake_logs` for auditing every voice → draft attempt.
Stores transcript, LLM raw JSON, the final action, and (optionally) a
MinIO object key that the audio lives at for the next 24h so the user
can undo. See docs/phase2-step2-voice-intake.md §2.
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


revision: str = 'f6a7b8c9d0e1'
down_revision: Union[str, None] = 'e5f6a7b8c9d0'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    voice_intake_status = sa.Enum(
        'STT_FAILED',
        'INTENT_UNKNOWN',
        'DRAFT_PENDING',
        'CONFIRMED',
        'CANCELED',
        name='voiceintakestatus',
    )

    op.create_table(
        'voice_intake_logs',
        sa.Column('id', sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column('user_id', sa.BigInteger(), nullable=False),
        sa.Column('request_id', sa.String(length=40), nullable=False),
        sa.Column('audio_object_key', sa.String(length=255), nullable=True),
        sa.Column('transcript', sa.Text(), nullable=True),
        sa.Column('llm_raw', sa.Text(), nullable=True),
        sa.Column('intent', sa.String(length=32), nullable=True),
        sa.Column('confidence', sa.Integer(), nullable=True),
        sa.Column('status', voice_intake_status, nullable=False),
        sa.Column('committed_entity_type', sa.String(length=32), nullable=True),
        sa.Column('committed_entity_id', sa.BigInteger(), nullable=True),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.Column('confirmed_at', sa.DateTime(), nullable=True),
        sa.ForeignKeyConstraint(['user_id'], ['users.id']),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('request_id', name='uq_voice_intake_logs_request_id'),
    )
    op.create_index(
        'ix_voice_intake_logs_user_id',
        'voice_intake_logs',
        ['user_id'],
    )
    op.create_index(
        'ix_voice_intake_logs_created_at',
        'voice_intake_logs',
        ['created_at'],
    )


def downgrade() -> None:
    op.drop_index('ix_voice_intake_logs_created_at', table_name='voice_intake_logs')
    op.drop_index('ix_voice_intake_logs_user_id', table_name='voice_intake_logs')
    op.drop_table('voice_intake_logs')

    bind = op.get_bind()
    if bind.dialect.name == 'postgresql':
        op.execute('DROP TYPE IF EXISTS voiceintakestatus')
