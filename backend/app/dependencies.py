from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.exceptions import AppException
from app.models.user import User
from app.utils.security import decode_token

_bearer = HTTPBearer(auto_error=False)


def _decode_access_token(credentials: HTTPAuthorizationCredentials | None) -> int:
    """Extract and validate a user id from the bearer token.

    Raises `AppException(401)` on missing / invalid / wrong-type tokens.
    Centralised so `get_current_user_id` and `get_current_user` share the
    exact same validation rules.
    """
    if credentials is None:
        raise AppException(401, "INVALID_ACCESS_TOKEN", "未提供访问令牌")

    payload = decode_token(credentials.credentials)
    if not payload or payload.get("type") != "access":
        raise AppException(401, "INVALID_ACCESS_TOKEN", "无效或已过期的访问令牌")

    try:
        return int(payload["sub"])
    except (KeyError, TypeError, ValueError):
        raise AppException(401, "INVALID_ACCESS_TOKEN", "无效或已过期的访问令牌")


async def get_current_user_id(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
) -> int:
    """Lightweight auth: decode the JWT and return the user id only.

    Use this for most routes (pets / photos / health) — skipping the
    `SELECT users WHERE id = ?` on every request saves one DB roundtrip
    per call. (Step 8 §1.1 rule 5 / Chunk B-6)

    Reserve `get_current_user` for endpoints that genuinely need the
    `User` ORM object (e.g. `PUT /auth/me`).
    """
    return _decode_access_token(credentials)


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    db: AsyncSession = Depends(get_db),
) -> User:
    user_id = _decode_access_token(credentials)
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()

    if user is None:
        raise AppException(401, "USER_NOT_FOUND", "用户不存在")

    return user
