"""Phase 2 Step 3 — photo auto-assign classify endpoint.

``POST /api/v1/photos/classify`` takes up to N images (multipart) and
returns one soft-guess ``pet_id`` per file. Decision math lives in
``app.services.pet_centroid``; the DashScope call lives in
``app.services.embedding``. This file is intentionally thin — it only
handles request validation, parallel dispatch and shaping the
response.

Error philosophy (see docs/phase2-step3 §6.4):
* **Request-level** failures (empty / too-many / bad-mime / oversize /
  empty-file) → ``400`` with the usual ``{code, message, details}``
  error envelope, because the client can correct them.
* **Upstream / model** failures → 200 with ``pet_id: null`` so a
  temporary DashScope outage never blocks the record flow. The user
  just gets the same UX as an uncertain match: tap-to-pick a pet.
"""
from __future__ import annotations

import asyncio
import logging
import time

from fastapi import APIRouter, Depends, File, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import settings
from app.database import get_db
from app.dependencies import get_current_user_id
from app.exceptions import AppException
from app.schemas.classify import ClassifyResponse, ClassifyResultItem
from app.services.embedding import EmbeddingUnavailableError, embed_image
from app.services.pet_centroid import classify as centroid_classify


logger = logging.getLogger(__name__)

router = APIRouter(prefix="/photos", tags=["classify"])


_ALLOWED_MIME = {"image/jpeg", "image/png", "image/webp"}


@router.post("/classify", response_model=ClassifyResponse)
async def classify_photos(
    files: list[UploadFile] = File(...),
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
) -> ClassifyResponse:
    if not files:
        raise AppException(400, "CLASSIFY_EMPTY", "至少提交一张照片")
    if len(files) > settings.CLASSIFY_MAX_FILES:
        raise AppException(
            400, "CLASSIFY_TOO_MANY",
            f"一次最多识别 {settings.CLASSIFY_MAX_FILES} 张",
        )

    # Eagerly read + validate before firing any embedding calls — cheaper
    # to refuse a 6-MB GIF here than after one upstream roundtrip.
    payloads: list[tuple[int, bytes]] = []
    for idx, f in enumerate(files):
        content_type = (f.content_type or "").lower()
        if content_type not in _ALLOWED_MIME:
            raise AppException(
                400, "CLASSIFY_BAD_MIME",
                f"第 {idx + 1} 张图片格式不支持",
            )
        data = await f.read()
        if not data:
            raise AppException(
                400, "CLASSIFY_EMPTY_FILE",
                f"第 {idx + 1} 张图片为空",
            )
        if len(data) > settings.CLASSIFY_MAX_FILE_BYTES:
            mb = settings.CLASSIFY_MAX_FILE_BYTES // (1024 * 1024)
            raise AppException(
                400, "CLASSIFY_TOO_LARGE",
                f"第 {idx + 1} 张图片超过 {mb}MB 限制",
            )
        payloads.append((idx, data))

    logger.info(
        "classify received user=%d count=%d total_bytes=%d",
        user_id, len(payloads), sum(len(d) for _, d in payloads),
    )

    # [DEBUG-2026-04-22] per-phase timing while we track the user-visible
    # 60s timeout. Drop the debug=... fields once the root cause is fixed.
    t_enter = time.perf_counter()

    async def _classify_one(idx: int, data: bytes) -> ClassifyResultItem:
        t0 = time.perf_counter()
        try:
            vec = await embed_image(data)
        except EmbeddingUnavailableError as e:
            # Soft-fail: let the user pick manually.
            logger.info(
                "classify idx=%d embedding unavailable after %.2fs: %s",
                idx, time.perf_counter() - t0, e,
            )
            return ClassifyResultItem(
                file_index=idx, pet_id=None, confidence=None,
            )
        except Exception as e:
            # Defensive: never leak a 5xx from the embedding path.
            logger.exception(
                "classify idx=%d unexpected error after %.2fs: %s",
                idx, time.perf_counter() - t0, e,
            )
            return ClassifyResultItem(
                file_index=idx, pet_id=None, confidence=None,
            )
        t_embed = time.perf_counter()

        result = await centroid_classify(db, user_id, vec)
        t_cls = time.perf_counter()
        logger.info(
            "classify idx=%d bytes=%d embed_ms=%d centroid_ms=%d pet_id=%s",
            idx, len(data),
            int((t_embed - t0) * 1000),
            int((t_cls - t_embed) * 1000),
            result.pet_id,
        )
        return ClassifyResultItem(
            file_index=idx,
            pet_id=result.pet_id,
            confidence=result.confidence,
        )

    results = await asyncio.gather(
        *(_classify_one(i, d) for i, d in payloads),
    )
    logger.info(
        "classify done user=%d count=%d total_ms=%d",
        user_id, len(payloads), int((time.perf_counter() - t_enter) * 1000),
    )
    # Keep the caller's original order so UI can zip directly with the
    # local file list.
    results_sorted = sorted(results, key=lambda r: r.file_index)
    return ClassifyResponse(results=results_sorted)
