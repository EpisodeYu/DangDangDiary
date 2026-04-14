from datetime import date, datetime
from decimal import Decimal
from pydantic import BaseModel

from app.models.deworming import DewormingType


class WeightCreate(BaseModel):
    weight_kg: Decimal
    recorded_at: date


class WeightResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    weight_kg: Decimal
    recorded_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class DewormingCreate(BaseModel):
    deworming_type: DewormingType
    dewormed_at: date


class DewormingResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    deworming_type: DewormingType
    dewormed_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class VaccinationCreate(BaseModel):
    vaccine_type: str
    vaccinated_at: date


class VaccinationResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    vaccine_type: str
    vaccinated_at: date
    created_at: datetime

    model_config = {"from_attributes": True}
