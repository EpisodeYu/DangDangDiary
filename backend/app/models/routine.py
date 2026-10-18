import enum
from datetime import date, datetime

from sqlalchemy import BigInteger, Boolean, Date, DateTime, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base
from app.utils.time import utcnow


class RoutineType(str, enum.Enum):
    BATH = "bath"
    NAIL_TRIM = "nail_trim"
    GROOMING = "grooming"


class Routine(Base):
    __tablename__ = "routines"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False, index=True)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    routine_type: Mapped[str] = mapped_column(String(64), nullable=False)
    performed_at: Mapped[date] = mapped_column(Date, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)


class RoutineItem(Base):
    __tablename__ = "routine_items"
    __table_args__ = (UniqueConstraint("pet_id", "routine_type"),)

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id", ondelete="CASCADE"), index=True)
    routine_type: Mapped[str] = mapped_column(String(64), nullable=False)
    name: Mapped[str] = mapped_column(String(20), nullable=False)
    cycle_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    reminder_enabled: Mapped[bool] = mapped_column(Boolean, default=False, nullable=False)
    deleted_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
