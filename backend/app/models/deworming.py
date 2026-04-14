import enum
from datetime import date, datetime

from sqlalchemy import BigInteger, Date, DateTime, Enum, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base


class DewormingType(str, enum.Enum):
    INTERNAL = "internal"
    EXTERNAL = "external"


class Deworming(Base):
    __tablename__ = "dewormings"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False, index=True)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    deworming_type: Mapped[DewormingType] = mapped_column(Enum(DewormingType), nullable=False)
    dewormed_at: Mapped[date] = mapped_column(Date, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
