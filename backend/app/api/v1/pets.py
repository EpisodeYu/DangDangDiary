from fastapi import APIRouter, Depends, Query, UploadFile, File
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.responses import Response

from app.database import get_db
from app.dependencies import get_current_user
from app.exceptions import AppException
from app.models.user import User
from app.schemas.pet import PetCreate, PetListResponse, PetResponse, PetUpdate
from app.services import pet as pet_service

router = APIRouter(prefix="/pets", tags=["pets"])

ALLOWED_AVATAR_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_AVATAR_SIZE = 5 * 1024 * 1024


@router.post("", response_model=PetResponse, status_code=201)
async def create_pet(
    data: PetCreate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    return await pet_service.create_pet(db, current_user.id, data)


@router.get("", response_model=PetListResponse)
async def list_pets(
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=100),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    pets, total = await pet_service.list_user_pets(db, current_user.id, page, page_size)
    return PetListResponse(page=page, page_size=page_size, total=total, pets=pets)


@router.get("/{pet_id}", response_model=PetResponse)
async def get_pet(
    pet_id: int,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    return await pet_service.get_pet_detail(db, pet_id, current_user.id)


@router.put("/{pet_id}", response_model=PetResponse)
async def update_pet(
    pet_id: int,
    data: PetUpdate,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    return await pet_service.update_pet(db, pet_id, current_user.id, data)


@router.post("/{pet_id}/avatar", response_model=PetResponse)
async def upload_avatar(
    pet_id: int,
    file: UploadFile = File(...),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    if file.content_type not in ALLOWED_AVATAR_TYPES:
        raise AppException(400, "PET_AVATAR_INVALID", "头像仅支持 JPG、PNG、WEBP 格式")

    file_data = await file.read()
    if len(file_data) > MAX_AVATAR_SIZE:
        raise AppException(400, "PET_AVATAR_TOO_LARGE", "头像文件大小不能超过 5MB")

    return await pet_service.upload_avatar(
        db, pet_id, current_user.id, file_data, file.content_type
    )


@router.delete("/{pet_id}", status_code=204)
async def delete_pet(
    pet_id: int,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await pet_service.delete_pet(db, pet_id, current_user.id)
    return Response(status_code=204)
