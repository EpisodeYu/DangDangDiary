"""Phase 2 Step 3 — /photos/classify request & response shapes."""
from __future__ import annotations

from pydantic import BaseModel


class ClassifyResultItem(BaseModel):
    """Per-file classify outcome.

    ``pet_id`` is ``None`` when the model couldn't confidently pick a
    pet — that includes "embedding upstream unavailable",
    "candidate pool empty", and "top-1 / margin below threshold". The
    client is expected to treat all three identically (show 「选择宠物」
    and let the user pick).
    """

    file_index: int
    pet_id: int | None = None
    confidence: float | None = None


class ClassifyResponse(BaseModel):
    results: list[ClassifyResultItem]
