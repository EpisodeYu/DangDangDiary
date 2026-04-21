"""Voice intake orchestration (Phase 2 Step 2).

Three entry points are exposed to the API layer:

* ``intake`` — STT → LLM → normalise → persist a draft log.
* ``confirm`` — dispatch a confirmed draft to the existing write
  services (health module etc.) and flip the log to ``CONFIRMED``.
* ``cancel`` — soft-cancel a ``DRAFT_PENDING`` log (5-second undo).

The module is written to be testable end-to-end without any real
network: the three upstream dependencies (STT, LLM, MinIO) are thin
wrappers that tests monkey-patch at the attribute boundary
(`voice_intake_service.stt_transcribe`, etc.).
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import uuid
from datetime import date, datetime, timedelta
from decimal import Decimal, InvalidOperation
from typing import Any

from fastapi import UploadFile
from pydantic import ValidationError
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.exceptions import AppException
from app.models.deworming import DewormingType
from app.models.pet import MemberRole, Pet, PetMember
from app.models.routine import RoutineType
from app.models.voice_intake import VoiceIntakeLog, VoiceIntakeStatus
from app.schemas.health import (
    DewormingCreate,
    RoutineCreate,
    VaccinationCreate,
    WeightCreate,
)
from app.schemas.voice_intake import (
    VoiceIntakeConfirmResponse,
    VoiceIntakeDraft,
    VoiceIntakeResponse,
)
from app.services import llm as _llm
from app.services import redis as _redis_mod
from app.services import stt as _stt
from app.services import storage as _storage
from app.services.health import (
    create_deworming,
    create_routine,
    create_vaccination,
    create_weight,
)
from app.utils.time import utcnow


logger = logging.getLogger(__name__)


# ---------------------------------------------------------------- consts

# MIME types accepted for voice intake; STT layer validates format too
# but we reject early so we don't even hit MinIO for a garbage upload.
ALLOWED_MIME_TYPES: frozenset[str] = frozenset({
    "audio/m4a",
    "audio/x-m4a",
    "audio/mp4",   # iOS records m4a in an mp4 container
    "audio/aac",
    "audio/mpeg",
    "audio/mp3",
    "audio/wav",
    "audio/x-wav",
})

# How long we cache `client_request_id → full response JSON` in Redis so
# that network retries from the phone don't double-charge STT and
# double-insert logs. 10min is plenty: user has at most 30s of audio +
# 5s undo window.
_CLIENT_DEDUP_TTL_SECONDS = 600

# Confidence thresholds used by the frontend to decide between
# "auto-commit + undo" and "show confirmation card". We return the raw
# integer so the client can tweak its UX independently, but expose the
# default threshold here as documentation.
AUTO_COMMIT_MIN_CONFIDENCE = 70


# Fields that must be present to confirm each intent. LLM-produced
# drafts missing any of these go to `missing_fields` and the phone
# navigates to the manual create form instead.
_REQUIRED_FIELDS: dict[str, list[str]] = {
    "deworming": ["pet_id", "deworming_type", "dewormed_at"],
    "vaccination": ["pet_id", "vaccine_name", "vaccinated_at"],
    "weight": ["pet_id", "weight_kg", "weighed_at"],
    "routine": ["pet_id", "routine_type", "routine_at"],
}


# --------------------------------------------------- date / enum helpers

_DATE_TODAY_RE = re.compile(r"^today$", re.IGNORECASE)
_DATE_YESTERDAY_RE = re.compile(r"^yesterday$", re.IGNORECASE)
_DATE_NDAYS_RE = re.compile(r"^n_days_ago:(\d+)$", re.IGNORECASE)
_DATE_ISO_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")


def _parse_date(value: Any, *, today: date) -> date | None:
    """Parse an LLM-produced date literal into a `date`.

    Accepts: `today`, `yesterday`, `N_days_ago:<n>`, `YYYY-MM-DD`.
    Returns `None` for anything else — including future dates — so the
    field falls into `missing_fields` rather than being silently wrong.
    """
    if value is None:
        return None
    if not isinstance(value, str):
        return None
    s = value.strip()
    if not s:
        return None
    if _DATE_TODAY_RE.match(s):
        return today
    if _DATE_YESTERDAY_RE.match(s):
        return today - timedelta(days=1)
    m = _DATE_NDAYS_RE.match(s)
    if m:
        n = int(m.group(1))
        if n < 0 or n > 3650:
            return None
        return today - timedelta(days=n)
    if _DATE_ISO_RE.match(s):
        try:
            d = date.fromisoformat(s)
        except ValueError:
            return None
        # Future dates are out of scope for a diary app; drop rather
        # than accept.
        if d > today:
            return None
        return d
    return None


def _parse_deworming_type(value: Any) -> str | None:
    if isinstance(value, str):
        v = value.strip().lower()
        if v in {"internal", "external", "combined"}:
            return v
    return None


def _parse_routine_type(value: Any) -> str | None:
    if isinstance(value, str):
        v = value.strip().lower()
        if v in {"bath", "nail_trim", "grooming"}:
            return v
    return None


def _parse_weight_kg(value: Any) -> float | None:
    if value is None:
        return None
    try:
        f = float(value)
    except (TypeError, ValueError):
        return None
    if f <= 0 or f > 200:
        return None
    return round(f, 2)


def _clamp_confidence(value: Any) -> int:
    try:
        c = int(value)
    except (TypeError, ValueError):
        return 0
    return max(0, min(100, c))


# ---------------------------------------------------- pet name matching


async def _fetch_user_pets(
    db: AsyncSession, user_id: int,
) -> list[Pet]:
    """Return every pet the user has access to (owner or shared EDITOR/VIEWER)."""
    result = await db.execute(
        select(Pet)
        .join(PetMember, PetMember.pet_id == Pet.id)
        .where(PetMember.user_id == user_id)
    )
    return list(result.scalars().all())


def _resolve_pet_from_closed_set(
    pets: list[Pet],
    *,
    llm_pet_name: str | None,
    default_pet_id: int | None,
) -> tuple[int | None, str | None]:
    """Given the user's full pet list and the LLM's closed-set choice,
    resolve to ``(pet_id, display_name)``.

    The LLM is instructed to return a string from the names we sent it,
    so we can do a case-insensitive direct lookup here. If the LLM
    didn't produce a name (quiet user, no match, or empty pet list) we
    fall back to the page's default pet.
    """
    if not pets:
        return None, None

    if llm_pet_name:
        target = llm_pet_name.strip().lower()
        if target:
            for p in pets:
                if p.name.lower() == target:
                    return p.id, p.name
            # LLM went off-script. Swallow rather than partial-match —
            # the closed set + explicit instructions make this rare, and
            # a wrong match is worse than a missing field.

    if default_pet_id is not None:
        for p in pets:
            if p.id == default_pet_id:
                return p.id, p.name
    return None, None


# ----------------------------------------------------- draft normaliser


def _normalize_draft(
    llm_output: dict[str, Any],
    *,
    pet_id: int | None,
    pet_display_name: str | None,
    today: date,
) -> tuple[VoiceIntakeDraft, str, int, str | None]:
    """Flatten the raw LLM dict into a ``VoiceIntakeDraft`` plus metadata.

    Returns ``(draft, intent, confidence, note)``. `intent` is always
    one of the five literals — unknown values collapse to ``unknown``.
    """
    raw_intent = llm_output.get("intent")
    intent = raw_intent if raw_intent in {
        "deworming", "vaccination", "weight", "routine", "unknown",
    } else "unknown"

    confidence = _clamp_confidence(llm_output.get("confidence"))
    note_raw = llm_output.get("note")
    note = note_raw.strip() if isinstance(note_raw, str) and note_raw.strip() else None

    draft = VoiceIntakeDraft(
        pet_id=pet_id,
        pet_name=pet_display_name,
        note=note,
        deworming_type=_parse_deworming_type(llm_output.get("deworming_type")),
        dewormed_at=_parse_date(llm_output.get("dewormed_at"), today=today),
        vaccine_name=(
            llm_output.get("vaccine_name").strip()
            if isinstance(llm_output.get("vaccine_name"), str)
            and llm_output.get("vaccine_name").strip()
            else None
        ),
        vaccinated_at=_parse_date(llm_output.get("vaccinated_at"), today=today),
        weight_kg=_parse_weight_kg(llm_output.get("weight_kg")),
        weighed_at=_parse_date(llm_output.get("weighed_at"), today=today),
        routine_type=_parse_routine_type(llm_output.get("routine_type")),
        routine_at=_parse_date(llm_output.get("routine_at"), today=today),
    )
    return draft, intent, confidence, note


def _compute_missing_fields(intent: str, draft: VoiceIntakeDraft) -> list[str]:
    required = _REQUIRED_FIELDS.get(intent, [])
    missing: list[str] = []
    dump = draft.model_dump()
    for f in required:
        if dump.get(f) in (None, ""):
            missing.append(f)
    return missing


# --------------------------------------------------- validation helpers


def _validate_audio_upload(audio: UploadFile, file_size: int) -> str:
    mime = (audio.content_type or "").lower()
    if mime not in ALLOWED_MIME_TYPES:
        raise AppException(
            400, "voice_audio_invalid",
            f"不支持的音频格式：{mime or '未知'}",
        )
    max_bytes = settings.VOICE_INTAKE_MAX_MB * 1024 * 1024
    if file_size <= 0:
        raise AppException(400, "voice_audio_invalid", "音频文件为空")
    if file_size > max_bytes:
        raise AppException(
            400, "voice_audio_invalid",
            f"音频文件过大（> {settings.VOICE_INTAKE_MAX_MB}MB）",
        )
    return mime


# ------------------------------------------------------------- intake


async def intake(
    db: AsyncSession,
    *,
    user_id: int,
    audio: UploadFile,
    default_pet_id: int | None,
    client_request_id: str,
) -> VoiceIntakeResponse:
    """Main entry. Returns a ``VoiceIntakeResponse`` — never raises on
    business-level failure (see §3.1: STT-failed / intent-unknown are
    200-level responses so the client's UX flow can branch cleanly)."""

    client_request_id = (client_request_id or "").strip()
    if not client_request_id or len(client_request_id) > 64:
        raise AppException(
            400, "voice_audio_invalid", "无效的 client_request_id",
        )

    # ---------- Redis dedup ----------
    dedup_key = f"voice:intake:client:{user_id}:{client_request_id}"
    try:
        cached = await _redis_mod.get_redis().get(dedup_key)
    except RuntimeError:
        cached = None
    if cached:
        try:
            return VoiceIntakeResponse.model_validate_json(cached)
        except ValidationError:
            logger.warning("corrupt cached intake response, ignoring: %r", cached[:200])

    # ---------- Read & validate audio ----------
    data = await audio.read()
    mime = _validate_audio_upload(audio, len(data))

    request_id = uuid.uuid4().hex
    today = date.today()

    # ---------- Upload to MinIO, then STT via presigned URL ----------
    # DashScope's async file-transcription API fetches the audio over
    # HTTP, so we upload once and hand it a presigned URL instead of
    # streaming the bytes through our process a second time.
    try:
        object_key = await _storage.aupload_voice_audio(
            user_id, data, mime, request_id=request_id,
        )
    except Exception as e:
        # MinIO being down is not the user's problem; treat as
        # upstream unavailability to surface a 503.
        logger.exception("minio upload failed: %s", e)
        raise AppException(
            503, "voice_upstream_unavailable",
            "音频暂存服务不可用，请稍后再试",
        )

    try:
        audio_url = await asyncio.to_thread(
            _storage.voice_audio_presigned_url, object_key,
        )
    except Exception as e:
        logger.exception("minio presign failed: %s", e)
        raise AppException(
            503, "voice_upstream_unavailable",
            "音频暂存服务不可用，请稍后再试",
        )

    # ---------- STT ----------
    try:
        transcript = await stt_transcribe(audio_url)
    except _stt.SttUnavailableError as e:
        logger.info("stt failed: %s", e)
        response = VoiceIntakeResponse(
            request_id=request_id,
            status="stt_failed",
            transcript=None,
            intent=None,
            confidence=None,
            needs_confirm=False,
            draft=None,
            missing_fields=[],
        )
        await _persist_log(
            db,
            user_id=user_id,
            request_id=request_id,
            audio_object_key=object_key,
            transcript=None,
            llm_raw=None,
            intent=None,
            confidence=None,
            status=VoiceIntakeStatus.STT_FAILED,
        )
        await _cache_dedup(dedup_key, response)
        return response

    # ---------- Fetch the user's full pet list for the LLM ----------
    # We pass the closed set of pet names so qwen-plus can do
    # homophone-tolerant matching (STT often mis-hears "咪咪" as
    # "米米", "小白" as "小柏", etc.). Default pet name is a
    # tie-breaker when the audio has no name at all.
    user_pets = await _fetch_user_pets(db, user_id)
    default_pet_name: str | None = None
    if default_pet_id is not None:
        for p in user_pets:
            if p.id == default_pet_id:
                default_pet_name = p.name
                break

    # ---------- LLM ----------
    try:
        llm_out = await llm_extract_intent(
            transcript,
            known_pet_names=[p.name for p in user_pets],
            default_pet_name=default_pet_name,
        )
    except _llm.LlmUnavailableError as e:
        logger.info("llm failed: %s", e)
        raise AppException(
            503, "voice_upstream_unavailable",
            "语义理解服务暂不可用，请稍后再试",
        )

    llm_raw = llm_out.pop("_raw", None)

    # ---------- Pet resolution (closed-set lookup) ----------
    llm_pet_name = llm_out.get("pet_name")
    if isinstance(llm_pet_name, str):
        llm_pet_name = llm_pet_name.strip() or None
    else:
        llm_pet_name = None

    pet_id, pet_display_name = _resolve_pet_from_closed_set(
        user_pets,
        llm_pet_name=llm_pet_name,
        default_pet_id=default_pet_id,
    )

    # ---------- Normalise ----------
    draft, intent, confidence, _note = _normalize_draft(
        llm_out,
        pet_id=pet_id,
        pet_display_name=pet_display_name,
        today=today,
    )

    if intent == "unknown":
        response = VoiceIntakeResponse(
            request_id=request_id,
            status="intent_unknown",
            transcript=transcript,
            intent="unknown",
            confidence=confidence,
            needs_confirm=False,
            draft=None,
            missing_fields=[],
        )
        await _persist_log(
            db,
            user_id=user_id,
            request_id=request_id,
            audio_object_key=object_key,
            transcript=transcript,
            llm_raw=llm_raw,
            intent="unknown",
            confidence=confidence,
            status=VoiceIntakeStatus.INTENT_UNKNOWN,
        )
        await _cache_dedup(dedup_key, response)
        return response

    # ---------- draft_pending ----------
    missing = _compute_missing_fields(intent, draft)
    needs_confirm = bool(missing) or confidence < AUTO_COMMIT_MIN_CONFIDENCE

    response = VoiceIntakeResponse(
        request_id=request_id,
        status="draft_pending",
        transcript=transcript,
        intent=intent,  # type: ignore[arg-type]
        confidence=confidence,
        needs_confirm=needs_confirm,
        draft=draft,
        missing_fields=missing,
    )
    await _persist_log(
        db,
        user_id=user_id,
        request_id=request_id,
        audio_object_key=object_key,
        transcript=transcript,
        llm_raw=llm_raw,
        intent=intent,
        confidence=confidence,
        status=VoiceIntakeStatus.DRAFT_PENDING,
    )
    await _cache_dedup(dedup_key, response)
    return response


async def _cache_dedup(key: str, response: VoiceIntakeResponse) -> None:
    try:
        await _redis_mod.get_redis().setex(
            key,
            _CLIENT_DEDUP_TTL_SECONDS,
            response.model_dump_json(),
        )
    except RuntimeError:
        pass


async def _persist_log(
    db: AsyncSession,
    *,
    user_id: int,
    request_id: str,
    audio_object_key: str | None,
    transcript: str | None,
    llm_raw: str | None,
    intent: str | None,
    confidence: int | None,
    status: VoiceIntakeStatus,
) -> VoiceIntakeLog:
    log = VoiceIntakeLog(
        user_id=user_id,
        request_id=request_id,
        audio_object_key=audio_object_key,
        transcript=transcript,
        llm_raw=llm_raw,
        intent=intent,
        confidence=confidence,
        status=status,
        created_at=utcnow(),
    )
    db.add(log)
    await db.flush()
    await db.commit()
    await db.refresh(log)
    return log


# Indirection so tests can monkeypatch without touching openai/dashscope.
async def stt_transcribe(audio_url: str) -> str:
    return await _stt.transcribe(audio_url)


async def llm_extract_intent(
    transcript: str,
    *,
    known_pet_names: list[str] | None = None,
    default_pet_name: str | None = None,
) -> dict[str, Any]:
    return await _llm.extract_intent(
        transcript,
        known_pet_names=known_pet_names,
        default_pet_name=default_pet_name,
    )


# ------------------------------------------------------------ confirm


_INTENT_ENTITY_TYPE = {
    "deworming": "deworming",
    "vaccination": "vaccination",
    "weight": "weight",
    "routine": "routine",
}


async def confirm(
    db: AsyncSession,
    *,
    user_id: int,
    request_id: str,
    intent: str,
    payload: dict[str, Any],
) -> VoiceIntakeConfirmResponse:
    # --- Look up the draft log (same user, draft_pending) ---
    result = await db.execute(
        select(VoiceIntakeLog).where(VoiceIntakeLog.request_id == request_id)
    )
    log = result.scalar_one_or_none()
    if log is None or log.user_id != user_id:
        raise AppException(
            404, "voice_intake_not_found", "语音草稿不存在",
        )
    if log.status != VoiceIntakeStatus.DRAFT_PENDING:
        raise AppException(
            409, "voice_intake_invalid_state",
            "该语音草稿状态不允许提交",
        )

    if intent not in _INTENT_ENTITY_TYPE:
        raise AppException(
            400, "voice_intake_invalid_intent", f"不支持的 intent：{intent}",
        )

    pet_id = payload.get("pet_id")
    if not isinstance(pet_id, int):
        raise AppException(
            400, "voice_intake_invalid_payload", "pet_id 必须为整数",
        )

    if intent == "deworming":
        entity, entity_type, entity_id = await _confirm_deworming(
            db, user_id, pet_id, payload,
        )
    elif intent == "vaccination":
        entity, entity_type, entity_id = await _confirm_vaccination(
            db, user_id, pet_id, payload,
        )
    elif intent == "weight":
        entity, entity_type, entity_id = await _confirm_weight(
            db, user_id, pet_id, payload,
        )
    else:  # routine
        entity, entity_type, entity_id = await _confirm_routine(
            db, user_id, pet_id, payload,
        )

    # Flip the log — note `create_*` already commits, but that's fine,
    # the log update is an independent transaction.
    log.status = VoiceIntakeStatus.CONFIRMED
    log.committed_entity_type = entity_type
    log.committed_entity_id = entity_id
    log.confirmed_at = utcnow()
    await db.flush()
    await db.commit()

    return VoiceIntakeConfirmResponse(
        request_id=request_id,
        status="confirmed",
        entity_type=entity_type,
        entity_id=entity_id,
        entity=json.loads(entity.model_dump_json()),
    )


async def _confirm_deworming(db, user_id, pet_id, payload):
    try:
        data = DewormingCreate(
            deworming_type=DewormingType(payload.get("deworming_type")),
            dewormed_at=_coerce_date(payload.get("dewormed_at")),
        )
    except (ValidationError, ValueError) as e:
        raise AppException(
            400, "voice_intake_invalid_payload",
            f"驱虫记录字段无效：{e}",
        )
    resp = await create_deworming(db, pet_id, user_id, data)
    return resp, "deworming", resp.id


async def _confirm_vaccination(db, user_id, pet_id, payload):
    try:
        data = VaccinationCreate(
            vaccine_type=payload.get("vaccine_name") or payload.get("vaccine_type") or "",
            vaccinated_at=_coerce_date(payload.get("vaccinated_at")),
        )
    except (ValidationError, ValueError) as e:
        raise AppException(
            400, "voice_intake_invalid_payload",
            f"疫苗记录字段无效：{e}",
        )
    resp = await create_vaccination(db, pet_id, user_id, data)
    return resp, "vaccination", resp.id


async def _confirm_weight(db, user_id, pet_id, payload):
    raw_weight = payload.get("weight_kg")
    try:
        weight = Decimal(str(raw_weight))
    except (InvalidOperation, TypeError):
        raise AppException(
            400, "voice_intake_invalid_payload", "weight_kg 格式错误",
        )
    try:
        data = WeightCreate(
            weight_kg=weight,
            recorded_at=_coerce_date(payload.get("weighed_at") or payload.get("recorded_at")),
        )
    except (ValidationError, ValueError) as e:
        raise AppException(
            400, "voice_intake_invalid_payload",
            f"体重记录字段无效：{e}",
        )
    resp = await create_weight(db, pet_id, user_id, data)
    return resp, "weight", resp.id


async def _confirm_routine(db, user_id, pet_id, payload):
    rtype = payload.get("routine_type")
    try:
        data = RoutineCreate(
            routine_type=RoutineType(rtype),
            performed_at=_coerce_date(
                payload.get("routine_at") or payload.get("performed_at"),
            ),
        )
    except (ValidationError, ValueError) as e:
        raise AppException(
            400, "voice_intake_invalid_payload",
            f"日常记录字段无效：{e}",
        )
    resp = await create_routine(db, pet_id, user_id, data)
    return resp, "routine", resp.id


def _coerce_date(value: Any) -> date:
    """Accept either an ISO string or an already-parsed `date`."""
    if isinstance(value, date) and not isinstance(value, datetime):
        return value
    if isinstance(value, datetime):
        return value.date()
    if isinstance(value, str):
        try:
            return date.fromisoformat(value)
        except ValueError as e:
            raise ValueError(f"invalid date {value!r}") from e
    raise ValueError("date value missing")


# ------------------------------------------------------------ cancel


async def cancel(
    db: AsyncSession,
    *,
    user_id: int,
    request_id: str,
) -> None:
    result = await db.execute(
        select(VoiceIntakeLog).where(VoiceIntakeLog.request_id == request_id)
    )
    log = result.scalar_one_or_none()
    if log is None or log.user_id != user_id:
        raise AppException(
            404, "voice_intake_not_found", "语音草稿不存在",
        )
    if log.status != VoiceIntakeStatus.DRAFT_PENDING:
        raise AppException(
            409, "voice_intake_invalid_state",
            "该语音草稿不允许取消",
        )

    log.status = VoiceIntakeStatus.CANCELED
    await db.flush()
    await db.commit()

    # Best-effort delete of the audio blob — if MinIO is down we leave
    # it to the 24h lifecycle.
    await _storage.adelete_voice_audio(log.audio_object_key)
