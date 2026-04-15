from fastapi import Depends
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.exceptions import AppException
from app.models.user import User
from app.utils.security import decode_token

_bearer = HTTPBearer(auto_error=False)


async def get_current_user(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer),
    db: AsyncSession = Depends(get_db),
) -> User:
    if credentials is None:
        raise AppException(401, "INVALID_ACCESS_TOKEN", "未提供访问令牌")

    payload = decode_token(credentials.credentials)
    if not payload or payload.get("type") != "access":
        raise AppException(401, "INVALID_ACCESS_TOKEN", "无效或已过期的访问令牌")

    user_id = int(payload["sub"])
    result = await db.execute(select(User).where(User.id == user_id))
    user = result.scalar_one_or_none()

    if user is None:
        raise AppException(401, "USER_NOT_FOUND", "用户不存在")

    return user
