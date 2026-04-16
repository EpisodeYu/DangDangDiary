import asyncio
import logging
import math
from datetime import date, datetime

from fastapi import APIRouter, Depends, File, Form, Query, UploadFile
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.responses import Response

from app.database import get_db
from app.dependencies import get_current_user
from app.exceptions import AppException
from app.models.photo import Photo
from app.models.user import User
from app.schemas.photo import (
    PhotoListResponse,
    PhotoOriginalUrlResponse,
    PhotoResponse,
    PhotoUploadFailure,
    PhotoUploadResponse,
    PhotoUploadSuccess,
)
from app.services.image_recognition import recognize_pet
from app.services.pet import get_pet_membership
from app.services.storage import (
    build_thumbnail_url,
    delete_photo_objects,
    get_photo_presigned_url,
    upload_photo,
)

logger = logging.getLogger(__name__)

router = APIRouter(tags=["photos"])

ALLOWED_CONTENT_TYPES = {"image/jpeg", "image/png", "image/webp"}
MAX_FILE_SIZE = 15 * 1024 * 1024  # 15 MB
MAX_FILES_PER_UPLOAD = 5


def _photo_to_response(photo: Photo) -> PhotoResponse:
    return PhotoResponse(
        id=photo.id,
        pet_id=photo.pet_id,
        user_id=photo.user_id,
        storage_key=photo.storage_key,
        thumbnail_key=photo.thumbnail_key or "",
        thumbnail_url=build_thumbnail_url(photo.thumbnail_key) if photo.thumbnail_key else "",
        taken_at=photo.taken_at,
        created_at=photo.created_at,
    )


@router.post("/pets/{pet_id}/photos", response_model=PhotoUploadResponse)
async def upload_photos(
    pet_id: int,
    taken_at: list[str] = Form(...),
    files: list[UploadFile] = File(...),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await get_pet_membership(pet_id, current_user.id, db)

    if not files:
        raise AppException(400, "EMPTY_UPLOAD", "没有上传任何文件")

    if len(files) > MAX_FILES_PER_UPLOAD:
        raise AppException(400, "TOO_MANY_FILES", f"一次最多上传 {MAX_FILES_PER_UPLOAD} 张照片")

    if len(taken_at) != len(files):
        raise AppException(400, "TAKEN_AT_MISMATCH", "拍摄日期数量必须与照片数量一致")

    parsed_dates: list[date] = []
    for ta in taken_at:
        try:
            parsed_dates.append(date.fromisoformat(ta))
        except (ValueError, TypeError):
            raise AppException(400, "INVALID_TAKEN_AT", f"拍摄日期格式不正确：{ta}，请使用 YYYY-MM-DD 格式")

    successes: list[PhotoUploadSuccess] = []
    failures: list[PhotoUploadFailure] = []

    for idx, file in enumerate(files):
        filename = file.filename or f"photo_{idx}"
        try:
            if file.content_type not in ALLOWED_CONTENT_TYPES:
                failures.append(PhotoUploadFailure(
                    index=idx, filename=filename,
                    code="UNSUPPORTED_IMAGE_TYPE",
                    message="不支持的图片格式，请上传 JPG、PNG 或 WEBP",
                ))
                continue

            file_data = await file.read()

            if len(file_data) > MAX_FILE_SIZE:
                failures.append(PhotoUploadFailure(
                    index=idx, filename=filename,
                    code="FILE_TOO_LARGE",
                    message="文件大小超过 15MB 限制",
                ))
                continue

            recognition = await asyncio.to_thread(recognize_pet, file_data)
            if not recognition["is_pet"]:
                failures.append(PhotoUploadFailure(
                    index=idx, filename=filename,
                    code="PET_NOT_DETECTED",
                    message="未识别到宠物，请换一张图片试试吧！",
                    details={"detected_labels": recognition["labels"]},
                ))
                continue

            try:
                storage_key, thumbnail_key = await asyncio.to_thread(
                    upload_photo, pet_id, file_data, file.content_type
                )
            except Exception as e:
                logger.error("Failed to upload photo to storage: %s", e)
                failures.append(PhotoUploadFailure(
                    index=idx, filename=filename,
                    code="PHOTO_UPLOAD_FAILED",
                    message="照片上传失败，请稍后重试",
                ))
                continue

            photo = Photo(
                pet_id=pet_id,
                user_id=current_user.id,
                storage_key=storage_key,
                thumbnail_key=thumbnail_key,
                taken_at=parsed_dates[idx],
                created_at=datetime.utcnow(),
            )
            db.add(photo)
            await db.flush()

            successes.append(PhotoUploadSuccess(
                index=idx,
                filename=filename,
                photo=_photo_to_response(photo),
            ))

        except Exception as e:
            logger.error("Unexpected error processing file %d (%s): %s", idx, filename, e)
            failures.append(PhotoUploadFailure(
                index=idx, filename=filename,
                code="PHOTO_UPLOAD_FAILED",
                message="照片处理失败",
            ))

    return PhotoUploadResponse(
        successes=successes,
        failures=failures,
        success_count=len(successes),
        failure_count=len(failures),
        total_count=len(files),
    )


@router.get("/pets/{pet_id}/photos", response_model=PhotoListResponse)
async def list_pet_photos(
    pet_id: int,
    page: int = Query(1, ge=1),
    page_size: int = Query(20, ge=1, le=50),
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    await get_pet_membership(pet_id, current_user.id, db)

    total_result = await db.execute(
        select(func.count()).select_from(Photo).where(Photo.pet_id == pet_id)
    )
    total = total_result.scalar() or 0
    total_pages = math.ceil(total / page_size) if total > 0 else 0

    offset = (page - 1) * page_size
    result = await db.execute(
        select(Photo)
        .where(Photo.pet_id == pet_id)
        .order_by(Photo.taken_at.desc(), Photo.created_at.desc(), Photo.id.desc())
        .offset(offset)
        .limit(page_size)
    )
    photos = result.scalars().all()

    return PhotoListResponse(
        photos=[_photo_to_response(p) for p in photos],
        total=total,
        page=page,
        page_size=page_size,
        total_pages=total_pages,
    )


@router.delete("/photos/{photo_id}", status_code=204)
async def delete_photo(
    photo_id: int,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(select(Photo).where(Photo.id == photo_id))
    photo = result.scalar_one_or_none()
    if photo is None:
        raise AppException(404, "PHOTO_NOT_FOUND", "照片不存在")

    await get_pet_membership(photo.pet_id, current_user.id, db)

    storage_key = photo.storage_key
    thumbnail_key = photo.thumbnail_key

    await db.delete(photo)
    await db.flush()

    delete_photo_objects(storage_key, thumbnail_key)

    return Response(status_code=204)


@router.get("/photos/{photo_id}/url", response_model=PhotoOriginalUrlResponse)
async def get_photo_url(
    photo_id: int,
    db: AsyncSession = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    result = await db.execute(select(Photo).where(Photo.id == photo_id))
    photo = result.scalar_one_or_none()
    if photo is None:
        raise AppException(404, "PHOTO_NOT_FOUND", "照片不存在")

    await get_pet_membership(photo.pet_id, current_user.id, db)

    expires_in = 3600
    url = get_photo_presigned_url(photo.storage_key, expires_in)

    return PhotoOriginalUrlResponse(url=url, expires_in=expires_in)


@router.get("/photos/timeline")
async def get_timeline():
    """Placeholder for Step 6 timeline."""
    return {"photos": []}
