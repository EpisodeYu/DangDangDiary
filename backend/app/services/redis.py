import redis.asyncio as aioredis

from app.config import settings

redis_client: aioredis.Redis | None = None


async def init_redis():
    global redis_client
    redis_client = aioredis.from_url(settings.REDIS_URL, decode_responses=True)


async def close_redis():
    global redis_client
    if redis_client:
        await redis_client.close()
        redis_client = None


def get_redis() -> aioredis.Redis:
    if redis_client is None:
        raise RuntimeError("Redis 未初始化")
    return redis_client


# ── Verification code ──

async def save_verify_code(phone: str, code: str):
    await get_redis().setex(f"sms:verify:{phone}", 300, code)


async def get_verify_code(phone: str) -> str | None:
    return await get_redis().get(f"sms:verify:{phone}")


async def delete_verify_code(phone: str):
    await get_redis().delete(f"sms:verify:{phone}")


# ── Rate limiting ──

async def is_rate_limited(phone: str) -> bool:
    return bool(await get_redis().exists(f"sms:limit:{phone}"))


async def set_rate_limit(phone: str):
    await get_redis().setex(f"sms:limit:{phone}", 60, "1")


# ── Refresh token blacklist ──

async def blacklist_refresh_token(token: str, ttl: int):
    await get_redis().setex(f"auth:refresh:blacklist:{token}", ttl, "1")


async def is_refresh_token_blacklisted(token: str) -> bool:
    return bool(await get_redis().exists(f"auth:refresh:blacklist:{token}"))
