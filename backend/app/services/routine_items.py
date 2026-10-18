"""Pet-scoped routine definitions. Deleted items remain available to history."""
import unicodedata
from uuid import uuid4

from sqlalchemy import select

from app.exceptions import AppException
from app.models.pet import MemberRole, Pet
from app.models.routine import RoutineItem
from app.schemas.health import RoutineItemResponse, RoutineResponse
from app.services.pet import get_pet_membership
from app.utils.time import utcnow

PRESETS = {"bath": "洗澡", "nail_trim": "剪指甲"}
MAX_CUSTOM_ITEMS = 10


async def lock_pet(db, pet_id, user_id):
    await get_pet_membership(pet_id, user_id, db, require_role=MemberRole.EDITOR)
    # All definition writes and routine creates share this lock. It makes the
    # quota/name checks and delete-vs-record races safe across app instances.
    return (await db.scalars(select(Pet).where(Pet.id == pet_id)
                            .with_for_update().execution_options(populate_existing=True))).one()


async def definitions(db, pet, *, include_deleted=False):
    result = [RoutineItemResponse(
        routine_type=key, name=name, is_preset=True,
        cycle_days=getattr(pet, f"{key}_cycle_days"),
        reminder_enabled=getattr(pet, f"{key}_reminder_enabled"),
    ) for key, name in PRESETS.items()]
    query = select(RoutineItem).where(RoutineItem.pet_id == pet.id).order_by(RoutineItem.id)
    if not include_deleted:
        query = query.where(RoutineItem.deleted_at.is_(None))
    result.extend(RoutineItemResponse.model_validate(item) for item in (await db.scalars(query)).all())
    return result


async def require_item(db, pet_id, key, *, allow_deleted=False):
    if key in PRESETS:
        return None
    item = (await db.scalars(select(RoutineItem).where(
        RoutineItem.pet_id == pet_id, RoutineItem.routine_type == key,
    ))).one_or_none()
    if item is None or (item.deleted_at is not None and not allow_deleted):
        raise AppException(400, "ROUTINE_ITEM_UNAVAILABLE", "日常事项不存在或已删除，请刷新后重试")
    return item


def clean_name(name):
    if not isinstance(name, str):
        raise AppException(400, "ROUTINE_NAME_INVALID", "请输入事项名称")
    name = unicodedata.normalize("NFKC", name).strip()
    if not 1 <= len(name) <= 20 or any(unicodedata.category(c).startswith("C") for c in name):
        raise AppException(400, "ROUTINE_NAME_INVALID", "事项名称须为 1–20 个可见字符")
    return name


async def unique_name(db, pet, name, *, excluding=None):
    names = await definitions(db, pet)
    if any(i.routine_type != excluding and i.name.casefold() == name.casefold() for i in names):
        raise AppException(409, "ROUTINE_NAME_EXISTS", "该宠物已有同名日常事项")


async def create_item(db, pet_id, user_id, data):
    pet = await lock_pet(db, pet_id, user_id)
    items = await definitions(db, pet)
    if sum(not i.is_preset for i in items) >= MAX_CUSTOM_ITEMS:
        raise AppException(400, "ROUTINE_ITEM_LIMIT", "每只宠物最多添加 10 项自定义日常")
    name = clean_name(data.name)
    await unique_name(db, pet, name)
    item = RoutineItem(pet_id=pet_id, routine_type=f"custom_{uuid4().hex}", name=name,
                       cycle_days=None, reminder_enabled=False)
    db.add(item)
    await db.flush()
    result = RoutineItemResponse.model_validate(item)
    await db.commit()
    return result


async def apply_settings(db, pet, key, updates):
    item = await require_item(db, pet.id, key)
    if "name" in updates:
        if item is None:
            raise AppException(400, "ROUTINE_PRESET_FIXED", "预置事项不能重命名")
        name = clean_name(updates["name"])
        await unique_name(db, pet, name, excluding=key)
        item.name = name
    if "reminder_enabled" in updates and updates["reminder_enabled"] is None:
        raise AppException(400, "ROUTINE_REMINDER_INVALID", "提醒开关不能为空")
    for field in ("cycle_days", "reminder_enabled"):
        if field in updates:
            if item is None:
                setattr(pet, f"{key}_{field}", updates[field])
            else:
                setattr(item, field, updates[field])
                if key == "grooming":
                    setattr(pet, f"grooming_{field}", updates[field])
    await db.flush()


async def update_item(db, pet_id, user_id, key, data):
    pet = await lock_pet(db, pet_id, user_id)
    await apply_settings(db, pet, key, data.model_dump(exclude_unset=True))
    result = next(i for i in await definitions(db, pet) if i.routine_type == key)
    await db.commit()
    return result


async def delete_item(db, pet_id, user_id, key):
    pet = await lock_pet(db, pet_id, user_id)
    if key in PRESETS:
        raise AppException(400, "ROUTINE_PRESET_FIXED", "预置事项不能删除")
    item = await require_item(db, pet_id, key)
    item.deleted_at = utcnow()
    item.reminder_enabled = False
    if key == "grooming":
        pet.grooming_reminder_enabled = False
    await db.commit()


async def serialize_records(db, pet_id, records):
    # One lookup per page/export; renamed and deleted items retain their names.
    items = (await db.scalars(select(RoutineItem).where(RoutineItem.pet_id == pet_id))).all()
    names = {i.routine_type: i for i in items}
    result = []
    for record in records:
        response = RoutineResponse.model_validate(record)
        item = names.get(record.routine_type)
        response.routine_name = PRESETS.get(record.routine_type) or (
            item.name if item else ("梳毛" if record.routine_type == "grooming" else "未知日常事项")
        )
        response.routine_deleted = item is not None and item.deleted_at is not None
        result.append(response)
    return result
