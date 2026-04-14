from datetime import date, datetime
from pydantic import BaseModel


class PhotoResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    thumbnail_url: str | None
    taken_at: date
    created_at: datetime

    model_config = {"from_attributes": True}
