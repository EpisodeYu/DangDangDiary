from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.exceptions import AppException
from app.models.pet import Pet, PetMember, PetShareCode, MemberRole
from app.schemas.pet import PetCreate, PetResponse, PetUpdate
from app.services.storage import (
    adelete_avatar,
    adelete_objects_by_prefix,
    aupload_pet_avatar,
)
from app.utils.invite_code import generate_invite_code
from app.utils.time import utcnow


# Strict ordering for "at-least" role checks. Higher value = more privilege.
ROLE_LEVEL: dict[MemberRole, int] = {
    MemberRole.VIEWER: 1,
    MemberRole.EDITOR: 2,
    MemberRole.OWNER: 3,
}


async def _unique_invite_code(db: AsyncSession) -> str:
    for _ in range(10):
        code = generate_invite_code()
        result = await db.execute(select(Pet).where(Pet.invite_code == code))
        if result.scalar_one_or_none() is None:
            return code
    raise AppException(500, "INVITE_CODE_GENERATION_FAILED", "邀请码生成失败，请重试")


def _build_pet_response(
    pet: Pet,
    role: MemberRole,
    *,
    share_code_active: bool = False,
) -> PetResponse:
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
        bath_cycle_days=pet.bath_cycle_days,
        nail_trim_cycle_days=pet.nail_trim_cycle_days,
        grooming_cycle_days=pet.grooming_cycle_days,
        bath_reminder_enabled=pet.bath_reminder_enabled,
        nail_trim_reminder_enabled=pet.nail_trim_reminder_enabled,
        grooming_reminder_enabled=pet.grooming_reminder_enabled,
        is_owner=is_owner,
        my_role=role,
        share_code_active=share_code_active if is_owner else False,
        created_at=pet.created_at,
        updated_at=pet.updated_at,
    )


async def _has_active_share_code(db: AsyncSession, pet_id: int) -> bool:
    now = utcnow()
    result = await db.execute(
        select(PetShareCode.id)
        .where(
            PetShareCode.pet_id == pet_id,
            PetShareCode.revoked_at.is_(None),
            PetShareCode.used_at.is_(None),
            PetShareCode.expires_at > now,
        )
        .limit(1)
    )
    return result.scalar_one_or_none() is not None


async def get_pet_membership(
    pet_id: int,
    user_id: int,
    db: AsyncSession,
    require_owner: bool = False,
    *,
    require_role: MemberRole | None = None,
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

    needed = MemberRole.OWNER if require_owner else require_role
    if needed is not None and ROLE_LEVEL[member.role] < ROLE_LEVEL[needed]:
        if needed == MemberRole.OWNER:
            raise AppException(
                403, "PET_OWNER_REQUIRED", "只有档案所有者才能执行此操作"
            )
        raise AppException(
            403, "PET_EDITOR_REQUIRED", "需要编辑权限才能执行此操作"
        )

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
    await db.commit()

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

    # share_code_active is only meaningful for owners; compute lazily.
    now = utcnow()
    owner_pet_ids = [pet.id for pet, role in rows if role == MemberRole.OWNER]
    active_owner_ids: set[int] = set()
    if owner_pet_ids:
        active_result = await db.execute(
            select(PetShareCode.pet_id)
            .where(
                PetShareCode.pet_id.in_(owner_pet_ids),
                PetShareCode.revoked_at.is_(None),
                PetShareCode.used_at.is_(None),
                PetShareCode.expires_at > now,
            )
            .distinct()
        )
        active_owner_ids = {pid for (pid,) in active_result.all()}

    pets = [
        _build_pet_response(
            pet, role, share_code_active=(pet.id in active_owner_ids),
        )
        for pet, role in rows
    ]
    return pets, total


async def get_pet_detail(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
) -> PetResponse:
    pet, member = await get_pet_membership(pet_id, user_id, db)
    active = (
        await _has_active_share_code(db, pet_id)
        if member.role == MemberRole.OWNER
        else False
    )
    return _build_pet_response(pet, member.role, share_code_active=active)


async def update_pet(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    data: PetUpdate,
) -> PetResponse:
    pet, member = await get_pet_membership(
        pet_id, user_id, db, require_role=MemberRole.EDITOR,
    )

    update_data = data.model_dump(exclude_unset=True)
    for field, value in update_data.items():
        setattr(pet, field, value)

    await db.flush()
    await db.commit()
    await db.refresh(pet)
    active = (
        await _has_active_share_code(db, pet_id)
        if member.role == MemberRole.OWNER
        else False
    )
    return _build_pet_response(pet, member.role, share_code_active=active)


async def upload_avatar(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
    file_data: bytes,
    content_type: str,
) -> PetResponse:
    pet, member = await get_pet_membership(
        pet_id, user_id, db, require_role=MemberRole.EDITOR,
    )

    old_avatar_url = pet.avatar_url

    new_url = await aupload_pet_avatar(pet_id, file_data, content_type)
    pet.avatar_url = new_url
    await db.flush()
    await db.commit()
    await db.refresh(pet)

    if old_avatar_url:
        await adelete_avatar(old_avatar_url)

    active = (
        await _has_active_share_code(db, pet_id)
        if member.role == MemberRole.OWNER
        else False
    )
    return _build_pet_response(pet, member.role, share_code_active=active)


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
    from app.models.routine import Routine

    for model in [
        Photo, Weight, Deworming, Vaccination, Routine,
        PetShareCode, PetMember,
    ]:
        await db.execute(
            select(model).where(model.pet_id == pet_id)
        )
        stmt = model.__table__.delete().where(model.pet_id == pet_id)
        await db.execute(stmt)

    await db.delete(pet)
    await db.flush()
    await db.commit()

    if avatar_url:
        await adelete_avatar(avatar_url)

    await adelete_objects_by_prefix(settings.MINIO_BUCKET_PHOTOS, f"{pet_id}/")
    await adelete_objects_by_prefix(settings.MINIO_BUCKET_THUMBNAILS, f"{pet_id}/")
    await adelete_objects_by_prefix(settings.MINIO_BUCKET_AVATARS, f"pets/{pet_id}/")
