from datetime import date, datetime
from pydantic import BaseModel


class PhotoResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    storage_key: str
    thumbnail_key: str
    thumbnail_url: str
    taken_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class PhotoUploadSuccess(BaseModel):
    index: int
    filename: str
    photo: PhotoResponse


class PhotoUploadFailure(BaseModel):
    index: int
    filename: str
    code: str
    message: str
    details: dict | None = None


class PhotoUploadResponse(BaseModel):
    successes: list[PhotoUploadSuccess]
    failures: list[PhotoUploadFailure]
    success_count: int
    failure_count: int
    total_count: int


class PhotoListResponse(BaseModel):
    photos: list[PhotoResponse]
    total: int
    page: int
    page_size: int
    total_pages: int


class PhotoOriginalUrlResponse(BaseModel):
    url: str
    expires_in: int
