from datetime import date, datetime

from pydantic import BaseModel, field_validator

from app.models.pet import MemberRole, PetType
from app.services.storage import build_avatar_url


class PetCreate(BaseModel):
    name: str
    pet_type: PetType
    breed: str | None = None
    birthday: date | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        value = value.strip()
        if not value or len(value) > 50:
            raise ValueError("宠物名字长度为1-50个字符")
        return value


class PetUpdate(BaseModel):
    name: str | None = None
    breed: str | None = None
    birthday: date | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str | None) -> str | None:
        if value is None:
            return value
        value = value.strip()
        if not value or len(value) > 50:
            raise ValueError("宠物名字长度为1-50个字符")
        return value


class PetResponse(BaseModel):
    id: int
    name: str
    pet_type: PetType
    breed: str | None
    birthday: date | None
    avatar_url: str | None
    # Deprecated since Phase 2 step1, kept for backward compatibility, will be
    # removed in a later step. Use the share-code APIs instead.
    invite_code: str | None
    internal_deworming_cycle_days: int | None
    external_deworming_cycle_days: int | None
    combined_deworming_cycle_days: int | None
    internal_reminder_enabled: bool
    external_reminder_enabled: bool
    combined_reminder_enabled: bool
    bath_cycle_days: int | None
    nail_trim_cycle_days: int | None
    grooming_cycle_days: int | None
    bath_reminder_enabled: bool
    nail_trim_reminder_enabled: bool
    grooming_reminder_enabled: bool
    is_owner: bool
    my_role: MemberRole
    share_code_active: bool = False
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}

    @field_validator("avatar_url", mode="after")
    @classmethod
    def _avatar_to_url(cls, v: str | None) -> str | None:
        return build_avatar_url(v)


class PetListResponse(BaseModel):
    page: int
    page_size: int
    total: int
    pets: list[PetResponse]
