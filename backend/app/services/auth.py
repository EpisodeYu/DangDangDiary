import secrets
from datetime import datetime, timezone

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import AppException
from app.models.user import User
from app.services import redis as redis_service
from app.services import sms as sms_service
from app.utils.security import create_access_token, create_refresh_token, decode_token


def _generate_default_nickname() -> str:
    return f"用户{secrets.token_hex(4)}"


async def send_code(phone: str):
    if await redis_service.is_rate_limited(phone):
        raise AppException(429, "SMS_RATE_LIMITED", "请求过于频繁，请60秒后重试")

    code = await sms_service.send_verify_code(phone)

    await redis_service.save_verify_code(phone, code)
    await redis_service.set_rate_limit(phone)


async def login(phone: str, code: str, db: AsyncSession) -> tuple[str, str, User]:
    stored_code = await redis_service.get_verify_code(phone)
    if not stored_code or stored_code != code:
        raise AppException(400, "INVALID_VERIFY_CODE", "验证码错误或已过期")

    await redis_service.delete_verify_code(phone)

    result = await db.execute(select(User).where(User.phone == phone))
    user = result.scalar_one_or_none()

    if user is None:
        user = User(phone=phone, nickname=_generate_default_nickname())
        db.add(user)
        await db.flush()
        await db.commit()

    access_token = create_access_token(user.id)
    refresh_token = create_refresh_token(user.id)
    return access_token, refresh_token, user


async def refresh_access_token(refresh_token: str, db: AsyncSession) -> str:
    payload = decode_token(refresh_token)
    if not payload or payload.get("type") != "refresh":
        raise AppException(401, "INVALID_REFRESH_TOKEN", "无效的刷新令牌")

    if await redis_service.is_refresh_token_blacklisted(refresh_token):
        raise AppException(401, "INVALID_REFRESH_TOKEN", "该刷新令牌已失效")

    user_id = int(payload["sub"])
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()
    if user is None:
        raise AppException(401, "INVALID_REFRESH_TOKEN", "用户不存在")

    return create_access_token(user_id)


async def logout(user_id: int, refresh_token: str):
    payload = decode_token(refresh_token)
    if not payload or payload.get("type") != "refresh":
        raise AppException(401, "INVALID_REFRESH_TOKEN", "无效的刷新令牌")

    token_user_id = int(payload["sub"])
    if token_user_id != user_id:
        raise AppException(400, "REFRESH_TOKEN_MISMATCH", "提交的刷新令牌与当前用户不匹配")

    exp = payload.get("exp", 0)
    remaining = max(int(exp - datetime.now(timezone.utc).timestamp()), 1)
    await redis_service.blacklist_refresh_token(refresh_token, remaining)
