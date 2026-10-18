"""Versioned, portable export data. No sharing credentials or signed URLs."""

from datetime import date, datetime

from pydantic import BaseModel

from app.schemas.health import (
    DewormingResponse, RoutineResponse, VaccinationResponse, WeightResponse,
)


class ExportPet(BaseModel):
    id: int
    name: str
    pet_type: str
    breed: str | None
    birthday: date | None
    avatar_url: str | None
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
    created_at: datetime
    updated_at: datetime

    model_config = {"from_attributes": True}


class ExportPhoto(BaseModel):
    id: int
    pet_id: int
    user_id: int
    storage_key: str
    taken_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class ExportRecords(BaseModel):
    weights: list[WeightResponse]
    dewormings: list[DewormingResponse]
    vaccinations: list[VaccinationResponse]
    routines: list[RoutineResponse]


class PetExportResponse(BaseModel):
    schema_version: int = 1
    exported_at: datetime
    pet: ExportPet
    photos: list[ExportPhoto] | None = None
    records: ExportRecords | None = None
