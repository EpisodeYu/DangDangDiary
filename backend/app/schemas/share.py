from datetime import datetime

from pydantic import BaseModel, field_validator

from app.models.pet import MemberRole
from app.services.storage import build_avatar_url


class ShareCodeResponse(BaseModel):
    code: str
    expires_at: datetime
    created_at: datetime

    model_config = {"from_attributes": True}


class ShareCodeRedeemRequest(BaseModel):
    code: str

    @field_validator("code")
    @classmethod
    def normalize(cls, v: str) -> str:
        v = (v or "").strip().upper()
        if len(v) != 8:
            raise ValueError("分享码必须为 8 位")
        return v


class PetMemberResponse(BaseModel):
    user_id: int
    nickname: str | None
    avatar_url: str | None
    role: MemberRole
    joined_at: datetime

    @field_validator("avatar_url", mode="after")
    @classmethod
    def _avatar_to_url(cls, v: str | None) -> str | None:
        return build_avatar_url(v)


class PetMembersResponse(BaseModel):
    members: list[PetMemberResponse]


class MemberUpdateRequest(BaseModel):
    role: MemberRole

    @field_validator("role")
    @classmethod
    def must_not_be_owner(cls, v: MemberRole) -> MemberRole:
        if v == MemberRole.OWNER:
            raise ValueError("不允许通过此接口设置 OWNER")
        return v
