from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.responses import Response

from app.database import get_db
from app.dependencies import get_current_user_id
from app.schemas.pet import PetResponse
from app.schemas.share import (
    MemberUpdateRequest,
    PetMemberResponse,
    PetMembersResponse,
    ShareCodeRedeemRequest,
    ShareCodeResponse,
)
from app.services import share as share_service


router = APIRouter(prefix="/pets", tags=["share"])


# Register the redeem route BEFORE the {pet_id} routes so it does not
# get shadowed by `/pets/{pet_id}/share-code` path matching.
@router.post("/redeem", response_model=PetResponse)
async def redeem_share_code(
    data: ShareCodeRedeemRequest,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await share_service.redeem_share_code(db, data.code, user_id)


@router.post(
    "/{pet_id}/share-code",
    response_model=ShareCodeResponse,
    status_code=201,
)
async def create_share_code(
    pet_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await share_service.generate_share_code(db, pet_id, user_id)


@router.get("/{pet_id}/share-code", response_model=ShareCodeResponse)
async def get_share_code(
    pet_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    code = await share_service.get_active_share_code(db, pet_id, user_id)
    if code is None:
        return Response(status_code=204)
    return code


@router.delete("/{pet_id}/share-code", status_code=204)
async def delete_share_code(
    pet_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    await share_service.revoke_active_share_code(db, pet_id, user_id)
    return Response(status_code=204)


@router.get("/{pet_id}/members", response_model=PetMembersResponse)
async def list_members(
    pet_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    members = await share_service.list_pet_members(db, pet_id, user_id)
    return PetMembersResponse(members=members)


@router.patch(
    "/{pet_id}/members/{member_user_id}",
    response_model=PetMemberResponse,
)
async def update_member(
    pet_id: int,
    member_user_id: int,
    data: MemberUpdateRequest,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    return await share_service.update_member_role(
        db, pet_id, member_user_id, data.role, user_id,
    )


@router.delete("/{pet_id}/members/{member_user_id}", status_code=204)
async def delete_member(
    pet_id: int,
    member_user_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    await share_service.remove_member(db, pet_id, member_user_id, user_id)
    return Response(status_code=204)


@router.post("/{pet_id}/leave", status_code=204)
async def leave_pet(
    pet_id: int,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    await share_service.leave_pet(db, pet_id, user_id)
    return Response(status_code=204)
