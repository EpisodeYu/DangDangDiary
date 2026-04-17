import math
from datetime import date, datetime, timedelta

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import AppException
from app.models.deworming import Deworming, DewormingType
from app.models.pet import Pet
from app.models.vaccination import Vaccination
from app.models.weight import Weight
from app.schemas.health import (
    DewormingCreate,
    DewormingCycleResponse,
    DewormingCycleUpdate,
    DewormingListResponse,
    DewormingResponse,
    DewormingStatusItem,
    DewormingStatusResponse,
    DewormingUpdate,
    VaccinationCreate,
    VaccinationListResponse,
    VaccinationResponse,
    VaccinationUpdate,
    WeightCreate,
    WeightListResponse,
    WeightResponse,
    WeightUpdate,
)
from app.services.pet import get_pet_membership


# ===================== Weight =====================

async def create_weight(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    data: WeightCreate,
) -> WeightResponse:
    await get_pet_membership(pet_id, user_id, db)

    weight = Weight(
        pet_id=pet_id,
        user_id=user_id,
        weight_kg=data.weight_kg,
        recorded_at=data.recorded_at,
        created_at=datetime.utcnow(),
    )
    db.add(weight)
    await db.flush()
    await db.refresh(weight)
    return WeightResponse.model_validate(weight)


async def list_weights(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    page: int,
    page_size: int,
) -> WeightListResponse:
    await get_pet_membership(pet_id, user_id, db)

    total_result = await db.execute(
        select(func.count()).select_from(Weight).where(Weight.pet_id == pet_id)
    )
    total = total_result.scalar() or 0
    total_pages = math.ceil(total / page_size) if total > 0 else 0

    offset = (page - 1) * page_size
    result = await db.execute(
        select(Weight)
        .where(Weight.pet_id == pet_id)
        .order_by(Weight.recorded_at.desc(), Weight.created_at.desc(), Weight.id.desc())
        .offset(offset)
        .limit(page_size)
    )
    weights = result.scalars().all()

    return WeightListResponse(
        weights=[WeightResponse.model_validate(w) for w in weights],
        total=total,
        page=page,
        page_size=page_size,
        total_pages=total_pages,
    )


async def update_weight(
    db: AsyncSession,
    weight_id: int,
    user_id: int,
    data: WeightUpdate,
) -> WeightResponse:
    result = await db.execute(select(Weight).where(Weight.id == weight_id))
    weight = result.scalar_one_or_none()
    if weight is None:
        raise AppException(404, "WEIGHT_NOT_FOUND", "体重记录不存在")

    await get_pet_membership(weight.pet_id, user_id, db)

    weight.weight_kg = data.weight_kg
    weight.recorded_at = data.recorded_at
    await db.flush()
    await db.refresh(weight)
    return WeightResponse.model_validate(weight)


async def delete_weight(
    db: AsyncSession,
    weight_id: int,
    user_id: int,
) -> None:
    result = await db.execute(select(Weight).where(Weight.id == weight_id))
    weight = result.scalar_one_or_none()
    if weight is None:
        raise AppException(404, "WEIGHT_NOT_FOUND", "体重记录不存在")

    await get_pet_membership(weight.pet_id, user_id, db)

    await db.delete(weight)
    await db.flush()


# ===================== Deworming =====================

async def create_deworming(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    data: DewormingCreate,
) -> DewormingResponse:
    await get_pet_membership(pet_id, user_id, db)

    deworming = Deworming(
        pet_id=pet_id,
        user_id=user_id,
        deworming_type=data.deworming_type,
        dewormed_at=data.dewormed_at,
        created_at=datetime.utcnow(),
    )
    db.add(deworming)
    await db.flush()
    await db.refresh(deworming)
    return DewormingResponse.model_validate(deworming)


async def list_dewormings(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    page: int,
    page_size: int,
) -> DewormingListResponse:
    await get_pet_membership(pet_id, user_id, db)

    total_result = await db.execute(
        select(func.count()).select_from(Deworming).where(Deworming.pet_id == pet_id)
    )
    total = total_result.scalar() or 0
    total_pages = math.ceil(total / page_size) if total > 0 else 0

    offset = (page - 1) * page_size
    result = await db.execute(
        select(Deworming)
        .where(Deworming.pet_id == pet_id)
        .order_by(
            Deworming.dewormed_at.desc(),
            Deworming.created_at.desc(),
            Deworming.id.desc(),
        )
        .offset(offset)
        .limit(page_size)
    )
    dewormings = result.scalars().all()

    return DewormingListResponse(
        dewormings=[DewormingResponse.model_validate(d) for d in dewormings],
        total=total,
        page=page,
        page_size=page_size,
        total_pages=total_pages,
    )


async def update_deworming(
    db: AsyncSession,
    deworming_id: int,
    user_id: int,
    data: DewormingUpdate,
) -> DewormingResponse:
    result = await db.execute(select(Deworming).where(Deworming.id == deworming_id))
    deworming = result.scalar_one_or_none()
    if deworming is None:
        raise AppException(404, "DEWORMING_NOT_FOUND", "驱虫记录不存在")

    await get_pet_membership(deworming.pet_id, user_id, db)

    deworming.deworming_type = data.deworming_type
    deworming.dewormed_at = data.dewormed_at
    await db.flush()
    await db.refresh(deworming)
    return DewormingResponse.model_validate(deworming)


async def delete_deworming(
    db: AsyncSession,
    deworming_id: int,
    user_id: int,
) -> None:
    result = await db.execute(select(Deworming).where(Deworming.id == deworming_id))
    deworming = result.scalar_one_or_none()
    if deworming is None:
        raise AppException(404, "DEWORMING_NOT_FOUND", "驱虫记录不存在")

    await get_pet_membership(deworming.pet_id, user_id, db)

    await db.delete(deworming)
    await db.flush()


async def update_deworming_cycle(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    data: DewormingCycleUpdate,
) -> DewormingCycleResponse:
    pet, _ = await get_pet_membership(pet_id, user_id, db)

    update_data = data.model_dump(exclude_unset=True)
    field_map = {
        "internal_cycle_days": "internal_deworming_cycle_days",
        "external_cycle_days": "external_deworming_cycle_days",
        "combined_cycle_days": "combined_deworming_cycle_days",
        "internal_reminder_enabled": "internal_reminder_enabled",
        "external_reminder_enabled": "external_reminder_enabled",
        "combined_reminder_enabled": "combined_reminder_enabled",
    }
    for key, value in update_data.items():
        column = field_map.get(key)
        if column is not None:
            setattr(pet, column, value)

    await db.flush()
    await db.refresh(pet)

    return DewormingCycleResponse(
        internal_cycle_days=pet.internal_deworming_cycle_days,
        external_cycle_days=pet.external_deworming_cycle_days,
        combined_cycle_days=pet.combined_deworming_cycle_days,
        internal_reminder_enabled=pet.internal_reminder_enabled,
        external_reminder_enabled=pet.external_reminder_enabled,
        combined_reminder_enabled=pet.combined_reminder_enabled,
    )


async def get_deworming_status(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
) -> DewormingStatusResponse:
    pet, _ = await get_pet_membership(pet_id, user_id, db)

    internal = await _calc_status(
        db, pet_id, DewormingType.INTERNAL,
        pet.internal_deworming_cycle_days, pet.internal_reminder_enabled,
    )
    external = await _calc_status(
        db, pet_id, DewormingType.EXTERNAL,
        pet.external_deworming_cycle_days, pet.external_reminder_enabled,
    )
    combined = await _calc_status(
        db, pet_id, DewormingType.COMBINED,
        pet.combined_deworming_cycle_days, pet.combined_reminder_enabled,
    )
    return DewormingStatusResponse(
        internal=internal,
        external=external,
        combined=combined,
    )


async def _calc_status(
    db: AsyncSession,
    pet_id: int,
    deworming_type: DewormingType,
    cycle_days: int | None,
    reminder_enabled: bool,
) -> DewormingStatusItem:
    result = await db.execute(
        select(Deworming)
        .where(
            Deworming.pet_id == pet_id,
            Deworming.deworming_type == deworming_type,
        )
        .order_by(Deworming.dewormed_at.desc(), Deworming.id.desc())
        .limit(1)
    )
    last = result.scalar_one_or_none()
    last_date = last.dewormed_at if last else None

    if not reminder_enabled:
        return DewormingStatusItem(
            reminder_enabled=False,
            last_dewormed_at=last_date,
            cycle_days=cycle_days,
            next_due_at=None,
            days_remaining=None,
            is_overdue=None,
        )

    if last_date is None or not cycle_days:
        return DewormingStatusItem(
            reminder_enabled=True,
            last_dewormed_at=last_date,
            cycle_days=cycle_days,
            next_due_at=None,
            days_remaining=None,
            is_overdue=None,
        )

    next_due = last_date + timedelta(days=cycle_days)
    remaining = (next_due - date.today()).days
    return DewormingStatusItem(
        reminder_enabled=True,
        last_dewormed_at=last_date,
        cycle_days=cycle_days,
        next_due_at=next_due,
        days_remaining=remaining,
        is_overdue=remaining < 0,
    )


# ===================== Vaccination =====================

VACCINE_PRESETS: dict[str, list[str]] = {
    "cat": [
        "猫三联疫苗",
        "狂犬病疫苗",
        "猫四联疫苗",
        "猫白血病疫苗",
        "猫五联疫苗",
        "猫传染性腹膜炎疫苗",
    ],
    "dog": [
        "狂犬病疫苗",
        "犬八联疫苗",
        "犬六联疫苗",
        "犬四联疫苗",
        "犬二联疫苗",
        "犬窝咳疫苗",
        "莱姆病疫苗",
        "犬流感疫苗",
    ],
}


async def create_vaccination(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    data: VaccinationCreate,
) -> VaccinationResponse:
    await get_pet_membership(pet_id, user_id, db)

    vaccination = Vaccination(
        pet_id=pet_id,
        user_id=user_id,
        vaccine_type=data.vaccine_type,
        vaccinated_at=data.vaccinated_at,
        created_at=datetime.utcnow(),
    )
    db.add(vaccination)
    await db.flush()
    await db.refresh(vaccination)
    return VaccinationResponse.model_validate(vaccination)


async def list_vaccinations(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    page: int,
    page_size: int,
) -> VaccinationListResponse:
    await get_pet_membership(pet_id, user_id, db)

    total_result = await db.execute(
        select(func.count()).select_from(Vaccination).where(Vaccination.pet_id == pet_id)
    )
    total = total_result.scalar() or 0
    total_pages = math.ceil(total / page_size) if total > 0 else 0

    offset = (page - 1) * page_size
    result = await db.execute(
        select(Vaccination)
        .where(Vaccination.pet_id == pet_id)
        .order_by(
            Vaccination.vaccinated_at.desc(),
            Vaccination.created_at.desc(),
            Vaccination.id.desc(),
        )
        .offset(offset)
        .limit(page_size)
    )
    records = result.scalars().all()

    return VaccinationListResponse(
        vaccinations=[VaccinationResponse.model_validate(r) for r in records],
        total=total,
        page=page,
        page_size=page_size,
        total_pages=total_pages,
    )


async def update_vaccination(
    db: AsyncSession,
    vaccination_id: int,
    user_id: int,
    data: VaccinationUpdate,
) -> VaccinationResponse:
    result = await db.execute(select(Vaccination).where(Vaccination.id == vaccination_id))
    record = result.scalar_one_or_none()
    if record is None:
        raise AppException(404, "VACCINATION_NOT_FOUND", "疫苗记录不存在")

    await get_pet_membership(record.pet_id, user_id, db)

    record.vaccine_type = data.vaccine_type
    record.vaccinated_at = data.vaccinated_at
    await db.flush()
    await db.refresh(record)
    return VaccinationResponse.model_validate(record)


async def delete_vaccination(
    db: AsyncSession,
    vaccination_id: int,
    user_id: int,
) -> None:
    result = await db.execute(select(Vaccination).where(Vaccination.id == vaccination_id))
    record = result.scalar_one_or_none()
    if record is None:
        raise AppException(404, "VACCINATION_NOT_FOUND", "疫苗记录不存在")

    await get_pet_membership(record.pet_id, user_id, db)

    await db.delete(record)
    await db.flush()
