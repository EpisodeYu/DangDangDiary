from datetime import date, datetime
from pydantic import BaseModel


class PhotoResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    storage_key: str
    thumbnail_key: str
    thumbnail_url: str
    # Smaller (~200 px) thumbnail used by the timeline grid. Empty string for
    # legacy rows uploaded before the small tier existed; the client should
    # fall back to `thumbnail_url` in that case.
    thumbnail_sm_url: str = ""
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


# ---------------- Timeline (Step 6) ----------------


class TimelinePhotoItem(BaseModel):
    id: int
    pet_id: int
    pet_name: str
    pet_type: str
    uploader_id: int
    uploader_nickname: str | None = None
    thumbnail_url: str
    # Smaller (~200 px) thumbnail. Empty for legacy rows; client falls back.
    thumbnail_sm_url: str = ""
    taken_at: date
    created_at: datetime


class TimelineGroup(BaseModel):
    # Optimization Step 2: bucket per day (was per month previously).
    # Days without any photo simply don't appear in the response.
    date: str  # "YYYY-MM-DD"
    label: str  # e.g. "2024年1月3日"
    photos: list[TimelinePhotoItem]


class TimelineDateRange(BaseModel):
    earliest: date | None = None
    latest: date | None = None


class TimelineWindowResponse(BaseModel):
    groups: list[TimelineGroup]
    total: int
    limit: int
    prev_cursor: str | None = None
    next_cursor: str | None = None
    has_more_newer: bool = False
    has_more_older: bool = False
    requested_anchor_month: str | None = None
    resolved_anchor_month: str | None = None
    date_range: TimelineDateRange


class DateDistributionItem(BaseModel):
    date: str  # "YYYY-MM"
    label: str
    count: int


class TimelineDatesResponse(BaseModel):
    months: list[DateDistributionItem]
    date_range: TimelineDateRange
