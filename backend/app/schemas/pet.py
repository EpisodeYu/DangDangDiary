from datetime import date, datetime
from pydantic import BaseModel

from app.models.pet import PetType, MemberRole


class PetCreate(BaseModel):
    name: str
    pet_type: PetType
    breed: str | None = None
    birthday: date | None = None


class PetUpdate(BaseModel):
    name: str | None = None
    breed: str | None = None
    birthday: date | None = None
    internal_deworming_cycle_days: int | None = None
    external_deworming_cycle_days: int | None = None


class PetResponse(BaseModel):
    id: int
    owner_id: int
    name: str
    pet_type: PetType
    breed: str | None
    birthday: date | None
    avatar_url: str | None
    invite_code: str
    internal_deworming_cycle_days: int | None
    external_deworming_cycle_days: int | None
    role: MemberRole | None = None
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}
