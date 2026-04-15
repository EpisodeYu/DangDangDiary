import pytest
import pytest_asyncio
from unittest.mock import patch, AsyncMock
from httpx import AsyncClient, ASGITransport
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker, AsyncSession
from sqlalchemy.dialects.sqlite.base import SQLiteTypeCompiler

from app.database import Base, get_db

# SQLite only auto-increments "INTEGER PRIMARY KEY" columns.
# BigInteger renders as "BIGINT" which breaks autoincrement — remap it.
SQLiteTypeCompiler.visit_big_integer = SQLiteTypeCompiler.visit_integer  # type: ignore[assignment]
SQLiteTypeCompiler.visit_BIGINT = SQLiteTypeCompiler.visit_INTEGER  # type: ignore[assignment]


@pytest.fixture(scope="session")
def anyio_backend():
    return "asyncio"


@pytest_asyncio.fixture()
async def test_engine():
    engine = create_async_engine("sqlite+aiosqlite:///:memory:")
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    yield engine
    await engine.dispose()


@pytest_asyncio.fixture()
async def client(test_engine):
    from app.main import app
    from app.services import redis as redis_mod

    session_maker = async_sessionmaker(
        test_engine, class_=AsyncSession, expire_on_commit=False
    )

    async def _override_get_db():
        async with session_maker() as session:
            try:
                yield session
                await session.commit()
            except Exception:
                await session.rollback()
                raise

    app.dependency_overrides[get_db] = _override_get_db

    store: dict[str, str] = {}

    async def _save_code(phone, code):
        store[f"sms:verify:{phone}"] = code

    async def _get_code(phone):
        return store.get(f"sms:verify:{phone}")

    async def _del_code(phone):
        store.pop(f"sms:verify:{phone}", None)

    async def _is_limited(phone):
        return f"sms:limit:{phone}" in store

    async def _set_limit(phone):
        store[f"sms:limit:{phone}"] = "1"

    async def _blacklist(token, ttl):
        store[f"auth:refresh:blacklist:{token}"] = "1"

    async def _is_blacklisted(token):
        return f"auth:refresh:blacklist:{token}" in store

    patches = [
        patch.object(redis_mod, "init_redis", new_callable=AsyncMock),
        patch.object(redis_mod, "close_redis", new_callable=AsyncMock),
        patch.object(redis_mod, "save_verify_code", side_effect=_save_code),
        patch.object(redis_mod, "get_verify_code", side_effect=_get_code),
        patch.object(redis_mod, "delete_verify_code", side_effect=_del_code),
        patch.object(redis_mod, "is_rate_limited", side_effect=_is_limited),
        patch.object(redis_mod, "set_rate_limit", side_effect=_set_limit),
        patch.object(redis_mod, "blacklist_refresh_token", side_effect=_blacklist),
        patch.object(redis_mod, "is_refresh_token_blacklisted", side_effect=_is_blacklisted),
    ]

    for p in patches:
        p.start()

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test/api/v1") as ac:
        yield ac, store

    for p in patches:
        p.stop()
    app.dependency_overrides.clear()


def _mock_sms_send(code: str = "123456"):
    """Return a patch context‑manager that mocks Aliyun SMS and captures the code."""
    from app.services import sms as sms_mod

    async def _fake_send(phone):
        return code

    return patch.object(sms_mod, "send_verify_code", side_effect=_fake_send)
