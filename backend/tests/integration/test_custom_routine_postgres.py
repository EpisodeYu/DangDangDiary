"""Opt-in local PostgreSQL migration and cross-connection concurrency checks."""
import asyncio
import importlib.util
import os
from pathlib import Path
from uuid import uuid4

import pytest
import pytest_asyncio
from alembic.migration import MigrationContext
from alembic.operations import Operations
from sqlalchemy import select, text
from sqlalchemy.engine import make_url
from sqlalchemy.ext.asyncio import async_sessionmaker, create_async_engine

from app.database import Base
from app.exceptions import AppException
from app.models.pet import MemberRole, Pet, PetMember, PetType
from app.models.routine import Routine, RoutineItem
from app.models.user import User
from app.schemas.health import RoutineItemCreate
from app.services import routine_items
from app.utils.time import utcnow

URL = os.environ.get('CUSTOM_ROUTINE_TEST_DATABASE_URL')
pytestmark = [pytest.mark.asyncio, pytest.mark.skipif(not URL, reason='local PostgreSQL URL not configured')]


def run_migration(connection, direction):
    path = Path(__file__).parents[2] / 'alembic/versions/d0e1f2a3b4c5_custom_routine_items.py'
    spec = importlib.util.spec_from_file_location('custom_routine_migration', path)
    migration = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(migration)
    with Operations.context(MigrationContext.configure(connection)):
        getattr(migration, direction)()


@pytest_asyncio.fixture
async def migrated_database():
    assert make_url(URL).host in ('127.0.0.1', 'localhost'), 'Only a local disposable database is allowed'
    schema = 'routine_test_' + uuid4().hex
    admin = create_async_engine(URL)
    async with admin.begin() as conn:
        await conn.execute(text(f'CREATE SCHEMA {schema}'))
    engine = create_async_engine(URL, connect_args={'server_settings': {'search_path': schema, 'timezone': 'Asia/Shanghai'}})
    try:
        async with engine.begin() as conn:
            await conn.run_sync(lambda c: Base.metadata.create_all(c, tables=[User.__table__, Pet.__table__, PetMember.__table__, Routine.__table__]))
            await conn.execute(text("CREATE TYPE routinetype AS ENUM ('BATH', 'NAIL_TRIM', 'GROOMING')"))
            await conn.execute(text('ALTER TABLE routines ALTER COLUMN routine_type TYPE routinetype USING upper(routine_type)::routinetype'))
        sessions = async_sessionmaker(engine, expire_on_commit=False)
        async with sessions() as db:
            user = User(phone='13800139999')
            db.add(user)
            await db.flush()
            pet = Pet(owner_id=user.id, name='迁移档案', pet_type=PetType.CAT, invite_code=uuid4().hex[:20], grooming_cycle_days=7, grooming_reminder_enabled=True)
            db.add(pet)
            await db.flush()
            db.add(PetMember(pet_id=pet.id, user_id=user.id, role=MemberRole.OWNER))
            await db.execute(text("INSERT INTO routines (pet_id,user_id,routine_type,performed_at,created_at) VALUES (:p,:u,'GROOMING','2026-10-01',CURRENT_TIMESTAMP)"), {'p': pet.id, 'u': user.id})
            await db.commit()
            ids = pet.id, user.id
        async with engine.begin() as conn:
            await conn.run_sync(run_migration, 'upgrade')
        yield sessions, ids
    finally:
        await engine.dispose()
        async with admin.begin() as conn:
            await conn.execute(text(f'DROP SCHEMA {schema} CASCADE'))
        await admin.dispose()


async def test_migration_preserves_history_settings_and_new_pet_defaults(migrated_database):
    sessions, (pet_id, uid) = migrated_database
    async with sessions() as db:
        pet = await db.get(Pet, pet_id)
        items = await routine_items.definitions(db, pet)
        assert [(i.routine_type, i.name, i.is_preset) for i in items] == [('bath', '洗澡', True), ('nail_trim', '剪指甲', True), ('grooming', '梳毛', False)]
        assert items[-1].cycle_days == 7 and items[-1].reminder_enabled is True
        migrated = (await db.scalars(select(RoutineItem))).one()
        assert abs((utcnow() - migrated.created_at).total_seconds()) < 60
        record = (await db.scalars(select(Routine))).one()
        assert record.routine_type == 'grooming' and record.performed_at.isoformat() == '2026-10-01'
        new = Pet(owner_id=uid, name='新档案', pet_type=PetType.DOG, invite_code=uuid4().hex[:20])
        db.add(new)
        await db.flush()
        assert [i.routine_type for i in await routine_items.definitions(db, new)] == ['bath', 'nail_trim']


async def test_parallel_quota_and_duplicate_name(migrated_database):
    sessions, (pet_id, uid) = migrated_database
    async def create(name):
        async with sessions() as db:
            try:
                return await routine_items.create_item(db, pet_id, uid, RoutineItemCreate(name=name))
            except AppException as e:
                await db.rollback()
                return e
    same = await asyncio.gather(create('刷牙'), create('刷牙'))
    assert sum(not isinstance(i, AppException) for i in same) == 1
    results = await asyncio.gather(*(create(f'事项{i}') for i in range(12)))
    assert sum(not isinstance(i, AppException) for i in results) == 8
    async with sessions() as db:
        active = (await db.scalars(select(RoutineItem).where(RoutineItem.deleted_at.is_(None)))).all()
        assert len(active) == 10  # migrated grooming + one toothbrush + eight new


async def test_unchanged_data_can_roundtrip_migration(migrated_database):
    sessions, _ = migrated_database
    async with sessions() as db:
        connection = await db.connection()
        await connection.run_sync(run_migration, 'downgrade')
        assert (await db.execute(text('SELECT routine_type::text FROM routines'))).scalar_one() == 'GROOMING'
        await connection.run_sync(run_migration, 'upgrade')
        assert (await db.scalars(select(Routine))).one().routine_type == 'grooming'
        assert (await db.scalars(select(RoutineItem))).one().cycle_days == 7


async def test_downgrade_refuses_to_discard_custom_data(migrated_database):
    sessions, (pet_id, uid) = migrated_database
    async with sessions() as db:
        await routine_items.create_item(db, pet_id, uid, RoutineItemCreate(name='刷牙'))
        connection = await db.connection()
        with pytest.raises(RuntimeError, match='Custom routine data exists'):
            await connection.run_sync(run_migration, 'downgrade')
        await db.rollback()
        assert len((await db.scalars(select(RoutineItem))).all()) == 2
