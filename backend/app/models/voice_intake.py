import enum
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Enum, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base
from app.utils.time import utcnow


class VoiceIntakeStatus(str, enum.Enum):
    STT_FAILED = "stt_failed"
    INTENT_UNKNOWN = "intent_unknown"
    DRAFT_PENDING = "draft_pending"
    CONFIRMED = "confirmed"
    CANCELED = "canceled"


class VoiceIntakeLog(Base):
    """Audit log of every voice → draft attempt.

    Stores transcript + LLM raw JSON + final action so we can (1) let the
    user undo within 5s, (2) regress prompts against real traffic, and
    (3) diagnose upstream failures. Audio blob itself is kept in MinIO
    with a 24h lifecycle; only the object key is stored here.
    """

    __tablename__ = "voice_intake_logs"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(
        BigInteger, ForeignKey("users.id"), nullable=False, index=True
    )
    request_id: Mapped[str] = mapped_column(String(40), unique=True, nullable=False)
    audio_object_key: Mapped[str | None] = mapped_column(String(255), nullable=True)
    transcript: Mapped[str | None] = mapped_column(Text, nullable=True)
    llm_raw: Mapped[str | None] = mapped_column(Text, nullable=True)
    intent: Mapped[str | None] = mapped_column(String(32), nullable=True)
    confidence: Mapped[int | None] = mapped_column(Integer, nullable=True)
    status: Mapped[VoiceIntakeStatus] = mapped_column(
        Enum(VoiceIntakeStatus), nullable=False
    )
    committed_entity_type: Mapped[str | None] = mapped_column(String(32), nullable=True)
    committed_entity_id: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[datetime] = mapped_column(
        DateTime, default=utcnow, index=True
    )
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
