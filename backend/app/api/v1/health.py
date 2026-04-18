from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.responses import Response

from app.database import get_db
from app.dependencies import get_current_user_id
from app.exceptions import AppException
from app.schemas.health import (
    DewormingCreate,
    DewormingCycleResponse,
    DewormingCycleUpdate,
    DewormingListResponse,
    DewormingResponse,
    DewormingStatusResponse,
    DewormingUpdate,
    RoutineCreate,
    RoutineCycleResponse,
    RoutineCycleUpdate,
    RoutineListResponse,
    RoutineResponse,
    RoutineStatusResponse,
    RoutineUpdate,
    VaccinationCreate,
    VaccinationListResponse,
    VaccinationResponse,
    VaccinationUpdate,
    VaccineTypePresetResponse,
    WeightCreate,
    WeightListResponse,
    WeightResponse,
    WeightUpdate,
)
from app.services import health as health_service
from app.services.health import VACCINE_PRESETS

router = APIRouter(tags=["health"])


# ================= Weights =================

@router.post("/pets/{pet_id}/weights", response_model=WeightResponse, status_code=201)
async def create_weight(
    pet_id: int,
    data: WeightCreate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.create_weight(db, pet_id, user_id, data)


@router.get("/pets/{pet_id}/weights", response_model=WeightListResponse)
async def list_weights(
    pet_id: int,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.list_weights(db, pet_id, user_id, page, page_size)


@router.put("/weights/{weight_id}", response_model=WeightResponse)
async def update_weight(
    weight_id: int,
    data: WeightUpdate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.update_weight(db, weight_id, user_id, data)


@router.delete("/weights/{weight_id}", status_code=204)
async def delete_weight(
    weight_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    await health_service.delete_weight(db, weight_id, user_id)
    return Response(status_code=204)


# ================= Dewormings =================

@router.post("/pets/{pet_id}/dewormings", response_model=DewormingResponse, status_code=201)
async def create_deworming(
    pet_id: int,
    data: DewormingCreate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.create_deworming(db, pet_id, user_id, data)


@router.get("/pets/{pet_id}/dewormings", response_model=DewormingListResponse)
async def list_dewormings(
    pet_id: int,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.list_dewormings(db, pet_id, user_id, page, page_size)


@router.put("/dewormings/{deworming_id}", response_model=DewormingResponse)
async def update_deworming(
    deworming_id: int,
    data: DewormingUpdate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.update_deworming(db, deworming_id, user_id, data)


@router.delete("/dewormings/{deworming_id}", status_code=204)
async def delete_deworming(
    deworming_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    await health_service.delete_deworming(db, deworming_id, user_id)
    return Response(status_code=204)


@router.put("/pets/{pet_id}/deworming-cycle", response_model=DewormingCycleResponse)
async def update_deworming_cycle(
    pet_id: int,
    data: DewormingCycleUpdate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.update_deworming_cycle(db, pet_id, user_id, data)


@router.get("/pets/{pet_id}/deworming-status", response_model=DewormingStatusResponse)
async def get_deworming_status(
    pet_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.get_deworming_status(db, pet_id, user_id)


# ================= Vaccinations =================

@router.post("/pets/{pet_id}/vaccinations", response_model=VaccinationResponse, status_code=201)
async def create_vaccination(
    pet_id: int,
    data: VaccinationCreate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.create_vaccination(db, pet_id, user_id, data)


@router.get("/pets/{pet_id}/vaccinations", response_model=VaccinationListResponse)
async def list_vaccinations(
    pet_id: int,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.list_vaccinations(db, pet_id, user_id, page, page_size)


@router.put("/vaccinations/{vaccination_id}", response_model=VaccinationResponse)
async def update_vaccination(
    vaccination_id: int,
    data: VaccinationUpdate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.update_vaccination(db, vaccination_id, user_id, data)


@router.delete("/vaccinations/{vaccination_id}", status_code=204)
async def delete_vaccination(
    vaccination_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    await health_service.delete_vaccination(db, vaccination_id, user_id)
    return Response(status_code=204)


@router.get("/vaccine-types", response_model=VaccineTypePresetResponse)
async def get_vaccine_types(
    pet_type: str = Query(..., description="宠物类型: cat / dog"),
    _: int = Depends(get_current_user_id),
):
    pet_type = pet_type.lower().strip()
    if pet_type not in VACCINE_PRESETS:
        raise AppException(400, "INVALID_PET_TYPE", "pet_type 必须是 cat 或 dog")
    return VaccineTypePresetResponse(
        preset_types=VACCINE_PRESETS[pet_type],
        pet_type=pet_type,
    )


# ================= Routines =================

@router.post("/pets/{pet_id}/routines", response_model=RoutineResponse, status_code=201)
async def create_routine(
    pet_id: int,
    data: RoutineCreate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.create_routine(db, pet_id, user_id, data)


@router.get("/pets/{pet_id}/routines", response_model=RoutineListResponse)
async def list_routines(
    pet_id: int,
    page: int = Query(1, ge=1),
    page_size: int = Query(50, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.list_routines(db, pet_id, user_id, page, page_size)


@router.put("/routines/{routine_id}", response_model=RoutineResponse)
async def update_routine(
    routine_id: int,
    data: RoutineUpdate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.update_routine(db, routine_id, user_id, data)


@router.delete("/routines/{routine_id}", status_code=204)
async def delete_routine(
    routine_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    await health_service.delete_routine(db, routine_id, user_id)
    return Response(status_code=204)


@router.put("/pets/{pet_id}/routine-cycle", response_model=RoutineCycleResponse)
async def update_routine_cycle(
    pet_id: int,
    data: RoutineCycleUpdate,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.update_routine_cycle(db, pet_id, user_id, data)


@router.get("/pets/{pet_id}/routine-status", response_model=RoutineStatusResponse)
async def get_routine_status(
    pet_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await health_service.get_routine_status(db, pet_id, user_id)
