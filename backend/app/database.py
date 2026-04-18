from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase

from app.config import settings


def _build_engine():
    url = settings.DATABASE_URL
    kwargs: dict = {"echo": settings.DB_ECHO}
    # SQLite (used in tests) ignores pool_size/max_overflow; apply tuning only
    # for real DB backends.
    if not url.startswith("sqlite"):
        kwargs.update(
            pool_size=settings.DB_POOL_SIZE,
            max_overflow=settings.DB_MAX_OVERFLOW,
            pool_pre_ping=True,
            pool_recycle=settings.DB_POOL_RECYCLE,
        )
    return create_async_engine(url, **kwargs)


engine = _build_engine()
async_session_maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


async def get_db():
    # No implicit commit: mutating service/route code is responsible for
    # calling `await db.commit()`. Read-only requests therefore run a single
    # transaction with no COMMIT at all.
    async with async_session_maker() as session:
        try:
            yield session
        except Exception:
            await session.rollback()
            raise
