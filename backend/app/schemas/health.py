from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, field_validator

from app.models.deworming import DewormingType
from app.models.routine import RoutineType


# ---------------- Weight ----------------

class WeightCreate(BaseModel):
    weight_kg: Decimal
    recorded_at: date

    @field_validator("weight_kg")
    @classmethod
    def validate_weight(cls, v: Decimal) -> Decimal:
        if v <= 0 or v > Decimal("200"):
            raise ValueError("体重必须在 0-200kg 之间")
        # At most 2 decimal places
        if v.as_tuple().exponent < -2:
            raise ValueError("体重最多保留两位小数")
        return v

    @field_validator("recorded_at")
    @classmethod
    def validate_date(cls, v: date) -> date:
        if v > date.today():
            raise ValueError("记录日期不能是未来日期")
        return v


class WeightUpdate(WeightCreate):
    pass


class WeightResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    weight_kg: Decimal
    recorded_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class WeightListResponse(BaseModel):
    weights: list[WeightResponse]
    total: int
    page: int
    page_size: int
    total_pages: int


# ---------------- Deworming ----------------

class DewormingCreate(BaseModel):
    deworming_type: DewormingType
    dewormed_at: date

    @field_validator("dewormed_at")
    @classmethod
    def validate_date(cls, v: date) -> date:
        if v > date.today():
            raise ValueError("驱虫日期不能是未来日期")
        return v


class DewormingUpdate(DewormingCreate):
    pass


class DewormingResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    deworming_type: DewormingType
    dewormed_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class DewormingListResponse(BaseModel):
    dewormings: list[DewormingResponse]
    total: int
    page: int
    page_size: int
    total_pages: int


class DewormingCycleUpdate(BaseModel):
    internal_cycle_days: int | None = None
    external_cycle_days: int | None = None
    combined_cycle_days: int | None = None
    internal_reminder_enabled: bool | None = None
    external_reminder_enabled: bool | None = None
    combined_reminder_enabled: bool | None = None

    @field_validator(
        "internal_cycle_days",
        "external_cycle_days",
        "combined_cycle_days",
    )
    @classmethod
    def validate_cycle(cls, v: int | None) -> int | None:
        if v is not None and (v < 1 or v > 365):
            raise ValueError("驱虫周期必须在 1-365 天之间")
        return v


class DewormingCycleResponse(BaseModel):
    internal_cycle_days: int | None
    external_cycle_days: int | None
    combined_cycle_days: int | None
    internal_reminder_enabled: bool
    external_reminder_enabled: bool
    combined_reminder_enabled: bool


class DewormingStatusItem(BaseModel):
    reminder_enabled: bool
    last_dewormed_at: date | None
    cycle_days: int | None
    next_due_at: date | None
    days_remaining: int | None
    is_overdue: bool | None


class DewormingStatusResponse(BaseModel):
    internal: DewormingStatusItem
    external: DewormingStatusItem
    combined: DewormingStatusItem


# ---------------- Vaccination ----------------

class VaccinationCreate(BaseModel):
    vaccine_type: str
    vaccinated_at: date

    @field_validator("vaccine_type")
    @classmethod
    def validate_type(cls, v: str) -> str:
        v = v.strip()
        if not v or len(v) > 100:
            raise ValueError("疫苗类型长度为1-100个字符")
        return v

    @field_validator("vaccinated_at")
    @classmethod
    def validate_date(cls, v: date) -> date:
        if v > date.today():
            raise ValueError("接种日期不能是未来日期")
        return v


class VaccinationUpdate(VaccinationCreate):
    pass


class VaccinationResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    vaccine_type: str
    vaccinated_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class VaccinationListResponse(BaseModel):
    vaccinations: list[VaccinationResponse]
    total: int
    page: int
    page_size: int
    total_pages: int


class VaccineTypePresetResponse(BaseModel):
    preset_types: list[str]
    pet_type: str


# ---------------- Routine ----------------

class RoutineCreate(BaseModel):
    routine_type: RoutineType
    performed_at: date

    @field_validator("performed_at")
    @classmethod
    def validate_date(cls, v: date) -> date:
        if v > date.today():
            raise ValueError("日常记录日期不能是未来日期")
        return v


class RoutineUpdate(RoutineCreate):
    pass


class RoutineResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    routine_type: RoutineType
    performed_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class RoutineListResponse(BaseModel):
    routines: list[RoutineResponse]
    total: int
    page: int
    page_size: int
    total_pages: int


class RoutineCycleUpdate(BaseModel):
    bath_cycle_days: int | None = None
    nail_trim_cycle_days: int | None = None
    grooming_cycle_days: int | None = None
    bath_reminder_enabled: bool | None = None
    nail_trim_reminder_enabled: bool | None = None
    grooming_reminder_enabled: bool | None = None

    @field_validator(
        "bath_cycle_days",
        "nail_trim_cycle_days",
        "grooming_cycle_days",
    )
    @classmethod
    def validate_cycle(cls, v: int | None) -> int | None:
        if v is not None and (v < 1 or v > 365):
            raise ValueError("日常周期必须在 1-365 天之间")
        return v


class RoutineCycleResponse(BaseModel):
    bath_cycle_days: int | None
    nail_trim_cycle_days: int | None
    grooming_cycle_days: int | None
    bath_reminder_enabled: bool
    nail_trim_reminder_enabled: bool
    grooming_reminder_enabled: bool


class RoutineStatusItem(BaseModel):
    reminder_enabled: bool
    last_performed_at: date | None
    cycle_days: int | None
    next_due_at: date | None
    days_remaining: int | None
    is_overdue: bool | None


class RoutineStatusResponse(BaseModel):
    bath: RoutineStatusItem
    nail_trim: RoutineStatusItem
    grooming: RoutineStatusItem
