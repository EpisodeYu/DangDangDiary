"""Pydantic models for Phase 2 Step 2 - voice intake (see docs/phase2-step2-voice-intake.md §3)."""

from datetime import date
from typing import Any, Literal

from pydantic import BaseModel, Field


# Supported voice intents. Keep aligned with §5 of the design doc and
# services.voice_intake._DISPATCH (both referenced by string literal).
VoiceIntent = Literal[
    "deworming",
    "vaccination",
    "weight",
    "routine",
    "unknown",
]


class VoiceIntakeDraft(BaseModel):
    """Structured, normalised draft produced by STT+LLM+normalisation.

    Every field is optional because missing ones go into `missing_fields`
    and the front-end will prompt for them. We deliberately don't
    sub-type per intent so the response stays a single stable shape; the
    server validates shape-vs-intent when the user confirms.
    """

    pet_id: int | None = None
    pet_name: str | None = None
    note: str | None = None

    # deworming
    deworming_type: Literal["internal", "external", "combined"] | None = None
    dewormed_at: date | None = None

    # vaccination
    vaccine_name: str | None = None
    vaccinated_at: date | None = None

    # weight
    weight_kg: float | None = None
    weighed_at: date | None = None

    # routine
    routine_type: Literal["bath", "nail_trim", "grooming"] | None = None
    routine_at: date | None = None


class VoiceIntakeResponse(BaseModel):
    """Returned by `POST /api/v1/voice/intake`."""

    request_id: str
    status: Literal[
        "stt_failed",
        "intent_unknown",
        "draft_pending",
    ]
    transcript: str | None = None
    intent: VoiceIntent | None = None
    confidence: int | None = None
    needs_confirm: bool = True
    draft: VoiceIntakeDraft | None = None
    missing_fields: list[str] = Field(default_factory=list)


class VoiceIntakeConfirmRequest(BaseModel):
    """Payload for `POST /api/v1/voice/intake/confirm`.

    `payload` is a free-form dict so each intent can pass its own
    field set; the server re-validates through the intent-specific
    Pydantic schema (DewormingCreate, etc.) before calling the
    existing write services.
    """

    request_id: str
    intent: VoiceIntent
    payload: dict[str, Any]


class VoiceIntakeConfirmResponse(BaseModel):
    request_id: str
    status: Literal["confirmed"]
    entity_type: str
    entity_id: int
    entity: dict[str, Any]
