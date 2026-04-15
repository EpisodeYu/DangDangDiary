import re

from pydantic import BaseModel, field_validator

_PHONE_RE = re.compile(r"^1[3-9]\d{9}$")
_CODE_RE = re.compile(r"^\d{6}$")


class SendCodeRequest(BaseModel):
    phone: str

    @field_validator("phone")
    @classmethod
    def validate_phone(cls, v: str) -> str:
        if not _PHONE_RE.match(v):
            raise ValueError("手机号格式不正确")
        return v


class SendCodeResponse(BaseModel):
    expire_seconds: int = 300


class LoginRequest(BaseModel):
    phone: str
    code: str

    @field_validator("phone")
    @classmethod
    def validate_phone(cls, v: str) -> str:
        if not _PHONE_RE.match(v):
            raise ValueError("手机号格式不正确")
        return v

    @field_validator("code")
    @classmethod
    def validate_code(cls, v: str) -> str:
        if not _CODE_RE.match(v):
            raise ValueError("验证码格式不正确")
        return v


class UserResponse(BaseModel):
    id: int
    phone: str
    nickname: str | None
    avatar_url: str | None

    model_config = {"from_attributes": True}


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    user: UserResponse


class RefreshRequest(BaseModel):
    refresh_token: str


class RefreshResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"


class LogoutRequest(BaseModel):
    refresh_token: str


class UpdateUserRequest(BaseModel):
    nickname: str

    @field_validator("nickname")
    @classmethod
    def validate_nickname(cls, v: str) -> str:
        v = v.strip()
        if not v:
            raise ValueError("昵称不能为空")
        return v
