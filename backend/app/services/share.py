from datetime import timedelta

from sqlalchemy import select, update
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import AppException
from app.models.pet import MemberRole, Pet, PetMember, PetShareCode
from app.models.user import User
from app.schemas.pet import PetResponse
from app.schemas.share import (
    PetMemberResponse,
    ShareCodeResponse,
)
from app.services.pet import _build_pet_response, get_pet_membership
from app.utils.invite_code import generate_invite_code
from app.utils.time import utcnow


SHARE_CODE_LENGTH = 8
SHARE_CODE_TTL_HOURS = 24
SHARE_CODE_GEN_RETRIES = 10


async def _generate_unique_code(db: AsyncSession) -> str:
    for _ in range(SHARE_CODE_GEN_RETRIES):
        candidate = generate_invite_code(length=SHARE_CODE_LENGTH)
        result = await db.execute(
            select(PetShareCode.id).where(PetShareCode.code == candidate)
        )
        if result.scalar_one_or_none() is None:
            return candidate
    raise AppException(
        500, "SHARE_CODE_GENERATION_FAILED", "分享码生成失败，请重试"
    )


async def _revoke_active_codes(db: AsyncSession, pet_id: int) -> None:
    now = utcnow()
    await db.execute(
        update(PetShareCode)
        .where(
            PetShareCode.pet_id == pet_id,
            PetShareCode.revoked_at.is_(None),
            PetShareCode.used_at.is_(None),
            PetShareCode.expires_at > now,
        )
        .values(revoked_at=now)
    )


async def generate_share_code(
    db: AsyncSession, pet_id: int, user_id: int,
) -> ShareCodeResponse:
    await get_pet_membership(pet_id, user_id, db, require_owner=True)

    await _revoke_active_codes(db, pet_id)

    now = utcnow()
    code = await _generate_unique_code(db)
    record = PetShareCode(
        pet_id=pet_id,
        code=code,
        created_by=user_id,
        expires_at=now + timedelta(hours=SHARE_CODE_TTL_HOURS),
        created_at=now,
    )
    db.add(record)
    await db.flush()
    await db.commit()
    await db.refresh(record)

    return ShareCodeResponse(
        code=record.code,
        expires_at=record.expires_at,
        created_at=record.created_at,
    )


async def get_active_share_code(
    db: AsyncSession, pet_id: int, user_id: int,
) -> ShareCodeResponse | None:
    await get_pet_membership(pet_id, user_id, db, require_owner=True)

    now = utcnow()
    result = await db.execute(
        select(PetShareCode)
        .where(
            PetShareCode.pet_id == pet_id,
            PetShareCode.revoked_at.is_(None),
            PetShareCode.used_at.is_(None),
            PetShareCode.expires_at > now,
        )
        .order_by(PetShareCode.created_at.desc())
        .limit(1)
    )
    record = result.scalar_one_or_none()
    if record is None:
        return None
    return ShareCodeResponse(
        code=record.code,
        expires_at=record.expires_at,
        created_at=record.created_at,
    )


async def revoke_active_share_code(
    db: AsyncSession, pet_id: int, user_id: int,
) -> None:
    await get_pet_membership(pet_id, user_id, db, require_owner=True)
    await _revoke_active_codes(db, pet_id)
    await db.commit()


async def redeem_share_code(
    db: AsyncSession, code: str, user_id: int,
) -> PetResponse:
    # `with_for_update` is silently ignored on SQLite (used by tests).
    stmt = select(PetShareCode).where(PetShareCode.code == code).with_for_update()
    result = await db.execute(stmt)
    record = result.scalar_one_or_none()

    if record is None:
        raise AppException(404, "SHARE_CODE_NOT_FOUND", "分享码不存在")
    if record.revoked_at is not None:
        raise AppException(400, "SHARE_CODE_REVOKED", "分享码已被撤回")
    if record.used_at is not None:
        raise AppException(400, "SHARE_CODE_USED", "分享码已被使用")
    if record.expires_at <= utcnow():
        raise AppException(400, "SHARE_CODE_EXPIRED", "分享码已过期")

    pet_result = await db.execute(select(Pet).where(Pet.id == record.pet_id))
    pet = pet_result.scalar_one_or_none()
    if pet is None:
        raise AppException(404, "PET_NOT_FOUND", "宠物档案不存在")

    if pet.owner_id == user_id:
        raise AppException(
            400, "SHARE_CODE_SELF_REDEEM", "不能兑换自己宠物的分享码"
        )

    member_result = await db.execute(
        select(PetMember).where(
            PetMember.pet_id == pet.id, PetMember.user_id == user_id,
        )
    )
    if member_result.scalar_one_or_none() is not None:
        raise AppException(
            400, "SHARE_ALREADY_MEMBER", "您已经是该宠物档案的共享成员"
        )

    now = utcnow()
    record.used_at = now
    record.used_by_user_id = user_id
    db.add(
        PetMember(
            pet_id=pet.id,
            user_id=user_id,
            role=MemberRole.VIEWER,
            created_at=now,
        )
    )
    await db.flush()
    await db.commit()

    return _build_pet_response(pet, MemberRole.VIEWER, share_code_active=False)


async def list_pet_members(
    db: AsyncSession, pet_id: int, user_id: int,
) -> list[PetMemberResponse]:
    await get_pet_membership(pet_id, user_id, db, require_owner=True)

    result = await db.execute(
        select(PetMember, User)
        .join(User, User.id == PetMember.user_id)
        .where(
            PetMember.pet_id == pet_id,
            PetMember.role != MemberRole.OWNER,
        )
        .order_by(PetMember.created_at.asc(), PetMember.id.asc())
    )
    rows = result.all()
    return [
        PetMemberResponse(
            user_id=user.id,
            nickname=user.nickname,
            avatar_url=user.avatar_url,
            role=member.role,
            joined_at=member.created_at,
        )
        for member, user in rows
    ]


async def update_member_role(
    db: AsyncSession,
    pet_id: int,
    member_user_id: int,
    new_role: MemberRole,
    user_id: int,
) -> PetMemberResponse:
    await get_pet_membership(pet_id, user_id, db, require_owner=True)

    if new_role not in (MemberRole.EDITOR, MemberRole.VIEWER):
        raise AppException(400, "SHARE_ROLE_INVALID", "不允许此角色变更")

    result = await db.execute(
        select(PetMember, User)
        .join(User, User.id == PetMember.user_id)
        .where(
            PetMember.pet_id == pet_id,
            PetMember.user_id == member_user_id,
        )
    )
    row = result.first()
    if row is None:
        raise AppException(404, "SHARE_MEMBER_NOT_FOUND", "分享成员不存在")
    member, user = row

    if member.role == MemberRole.OWNER:
        raise AppException(400, "SHARE_ROLE_INVALID", "不允许此角色变更")

    member.role = new_role
    await db.flush()
    await db.commit()
    await db.refresh(member)

    return PetMemberResponse(
        user_id=user.id,
        nickname=user.nickname,
        avatar_url=user.avatar_url,
        role=member.role,
        joined_at=member.created_at,
    )


async def remove_member(
    db: AsyncSession,
    pet_id: int,
    member_user_id: int,
    user_id: int,
) -> None:
    await get_pet_membership(pet_id, user_id, db, require_owner=True)

    if member_user_id == user_id:
        raise AppException(400, "SHARE_ROLE_INVALID", "不允许此角色变更")

    result = await db.execute(
        select(PetMember).where(
            PetMember.pet_id == pet_id,
            PetMember.user_id == member_user_id,
        )
    )
    member = result.scalar_one_or_none()
    if member is None:
        raise AppException(404, "SHARE_MEMBER_NOT_FOUND", "分享成员不存在")
    if member.role == MemberRole.OWNER:
        raise AppException(400, "SHARE_ROLE_INVALID", "不允许此角色变更")

    await db.delete(member)
    await db.flush()
    await db.commit()
