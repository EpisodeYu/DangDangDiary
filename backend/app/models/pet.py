import enum
from datetime import date, datetime

from sqlalchemy import BigInteger, Boolean, String, Date, DateTime, Integer, Enum, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class PetType(str, enum.Enum):
    CAT = "cat"
    DOG = "dog"


class MemberRole(str, enum.Enum):
    OWNER = "owner"
    MEMBER = "member"


class Pet(Base):
    __tablename__ = "pets"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    owner_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(50), nullable=False)
    pet_type: Mapped[PetType] = mapped_column(Enum(PetType), nullable=False)
    breed: Mapped[str | None] = mapped_column(String(50), nullable=True)
    birthday: Mapped[date | None] = mapped_column(Date, nullable=True)
    avatar_url: Mapped[str | None] = mapped_column(String(500), nullable=True)
    invite_code: Mapped[str] = mapped_column(String(20), unique=True, nullable=False)
    internal_deworming_cycle_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    external_deworming_cycle_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    combined_deworming_cycle_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    internal_reminder_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    external_reminder_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    combined_reminder_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    bath_cycle_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    nail_trim_cycle_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    grooming_cycle_days: Mapped[int | None] = mapped_column(Integer, nullable=True)
    bath_reminder_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    nail_trim_reminder_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    grooming_reminder_enabled: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime, default=datetime.utcnow, onupdate=datetime.utcnow
    )


class PetMember(Base):
    __tablename__ = "pet_members"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    role: Mapped[MemberRole] = mapped_column(Enum(MemberRole), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
