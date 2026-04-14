from pydantic import BaseModel
from typing import Any


class ErrorResponse(BaseModel):
    code: str
    message: str
    details: Any = None
