from datetime import datetime, timezone

from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import AppException
from app.models.deworming import Deworming
from app.models.photo import Photo
from app.models.routine import Routine
from app.models.vaccination import Vaccination
from app.models.weight import Weight
from app.schemas.pet_export import (
    ExportPet, ExportPhoto, ExportRecords, PetExportResponse,
)
from app.services.pet import get_pet_membership


async def get_pet_export(
    db: AsyncSession, pet_id: int, user_id: int,
    *, photos: bool, records: bool,
) -> PetExportResponse:
    if not photos and not records:
        raise AppException(400, "EXPORT_EMPTY_SELECTION", "请至少选择照片或记录")

    # Keep all lists and profile settings at the same database snapshot. This
    # request owns a fresh read-only session; no OFFSET pagination can skip rows
    # when another member adds/deletes records during an export.
    if db.bind.dialect.name == "postgresql":
        await db.execute(text("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY"))
    pet, _ = await get_pet_membership(pet_id, user_id, db)

    async def rows(model, date_column):
        return (await db.scalars(
            select(model).where(model.pet_id == pet_id)
            .order_by(date_column.desc(), model.id.desc())
        )).all()

    result = PetExportResponse(
        exported_at=datetime.now(timezone.utc),
        pet=ExportPet.model_validate(pet),
    )
    if photos:
        result.photos = [ExportPhoto.model_validate(row)
                         for row in await rows(Photo, Photo.taken_at)]
    if records:
        result.records = ExportRecords(
            weights=await rows(Weight, Weight.recorded_at),
            dewormings=await rows(Deworming, Deworming.dewormed_at),
            vaccinations=await rows(Vaccination, Vaccination.vaccinated_at),
            routines=await rows(Routine, Routine.performed_at),
        )
    return result
