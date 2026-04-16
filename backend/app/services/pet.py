from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.exceptions import AppException
from app.models.pet import Pet, PetMember, MemberRole
from app.schemas.pet import PetCreate, PetResponse, PetUpdate
from app.services.storage import (
    delete_object_by_url,
    delete_objects_by_prefix,
    upload_pet_avatar,
)
from app.utils.invite_code import generate_invite_code


async def _unique_invite_code(db: AsyncSession) -> str:
    for _ in range(10):
        code = generate_invite_code()
        result = await db.execute(select(Pet).where(Pet.invite_code == code))
        if result.scalar_one_or_none() is None:
            return code
    raise AppException(500, "INVITE_CODE_GENERATION_FAILED", "邀请码生成失败，请重试")


def _build_pet_response(pet: Pet, role: MemberRole) -> PetResponse:
    is_owner = role == MemberRole.OWNER
    return PetResponse(
        id=pet.id,
        name=pet.name,
        pet_type=pet.pet_type,
        breed=pet.breed,
        birthday=pet.birthday,
        avatar_url=pet.avatar_url,
        invite_code=pet.invite_code if is_owner else None,
        internal_deworming_cycle_days=pet.internal_deworming_cycle_days,
        external_deworming_cycle_days=pet.external_deworming_cycle_days,
        combined_deworming_cycle_days=pet.combined_deworming_cycle_days,
        internal_reminder_enabled=pet.internal_reminder_enabled,
        external_reminder_enabled=pet.external_reminder_enabled,
        combined_reminder_enabled=pet.combined_reminder_enabled,
        is_owner=is_owner,
        my_role=role,
        created_at=pet.created_at,
        updated_at=pet.updated_at,
    )


async def get_pet_membership(
    pet_id: int,
    user_id: int,
    db: AsyncSession,
    require_owner: bool = False,
) -> tuple[Pet, PetMember]:
    result = await db.execute(select(Pet).where(Pet.id == pet_id))
    pet = result.scalar_one_or_none()
    if pet is None:
        raise AppException(404, "PET_NOT_FOUND", "宠物档案不存在")

    result = await db.execute(
        select(PetMember).where(
            PetMember.pet_id == pet_id,
            PetMember.user_id == user_id,
        )
    )
    member = result.scalar_one_or_none()
    if member is None:
        raise AppException(403, "PET_FORBIDDEN", "您无权访问此宠物档案")

    if require_owner and member.role != MemberRole.OWNER:
        raise AppException(403, "PET_OWNER_REQUIRED", "只有档案所有者才能执行此操作")

    return pet, member


async def create_pet(
    db: AsyncSession,
    user_id: int,
    data: PetCreate,
) -> PetResponse:
    invite_code = await _unique_invite_code(db)

    pet = Pet(
        owner_id=user_id,
        name=data.name,
        pet_type=data.pet_type,
        breed=data.breed,
        birthday=data.birthday,
        invite_code=invite_code,
    )
    db.add(pet)
    await db.flush()

    member = PetMember(
        pet_id=pet.id,
        user_id=user_id,
        role=MemberRole.OWNER,
    )
    db.add(member)
    await db.flush()

    return _build_pet_response(pet, MemberRole.OWNER)


async def list_user_pets(
    db: AsyncSession,
    user_id: int,
    page: int,
    page_size: int,
) -> tuple[list[PetResponse], int]:
    base_query = (
        select(Pet, PetMember.role)
        .join(PetMember, PetMember.pet_id == Pet.id)
        .where(PetMember.user_id == user_id)
    )

    count_query = (
        select(func.count())
        .select_from(Pet)
        .join(PetMember, PetMember.pet_id == Pet.id)
        .where(PetMember.user_id == user_id)
    )
    total_result = await db.execute(count_query)
    total = total_result.scalar() or 0

    offset = (page - 1) * page_size
    data_query = (
        base_query
        .order_by(Pet.created_at.desc(), Pet.id.desc())
        .offset(offset)
        .limit(page_size)
    )
    result = await db.execute(data_query)
    rows = result.all()

    pets = [_build_pet_response(pet, role) for pet, role in rows]
    return pets, total


async def get_pet_detail(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
) -> PetResponse:
    pet, member = await get_pet_membership(pet_id, user_id, db)
    return _build_pet_response(pet, member.role)


async def update_pet(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    data: PetUpdate,
) -> PetResponse:
    pet, member = await get_pet_membership(pet_id, user_id, db, require_owner=True)

    update_data = data.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(pet, field, value)

    await db.flush()
    await db.refresh(pet)
    return _build_pet_response(pet, member.role)


async def upload_avatar(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    file_data: bytes,
    content_type: str,
) -> PetResponse:
    pet, member = await get_pet_membership(pet_id, user_id, db, require_owner=True)

    old_avatar_url = pet.avatar_url

    new_url = upload_pet_avatar(pet_id, file_data, content_type)
    pet.avatar_url = new_url
    await db.flush()
    await db.refresh(pet)

    if old_avatar_url:
        delete_object_by_url(old_avatar_url)

    return _build_pet_response(pet, member.role)


async def delete_pet(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
) -> None:
    pet, _ = await get_pet_membership(pet_id, user_id, db, require_owner=True)

    avatar_url = pet.avatar_url

    from app.models.photo import Photo
    from app.models.weight import Weight
    from app.models.deworming import Deworming
    from app.models.vaccination import Vaccination

    for model in [Photo, Weight, Deworming, Vaccination, PetMember]:
        await db.execute(
            select(model).where(model.pet_id == pet_id)
        )
        stmt = model.__table__.delete().where(model.pet_id == pet_id)
        await db.execute(stmt)

    await db.delete(pet)
    await db.flush()

    if avatar_url:
        delete_object_by_url(avatar_url)

    delete_objects_by_prefix(settings.MINIO_BUCKET_PHOTOS, f"{pet_id}/")
    delete_objects_by_prefix(settings.MINIO_BUCKET_THUMBNAILS, f"{pet_id}/")
    delete_objects_by_prefix(settings.MINIO_BUCKET_AVATARS, f"pets/{pet_id}/")
