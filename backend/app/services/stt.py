"""DashScope Paraformer STT thin wrapper.

Uses the **async file-transcription** API (``dashscope.audio.asr.Transcription``)
with the ``paraformer-v1`` model. Compared with the realtime model's
synchronous-file mode (``paraformer-realtime-v2`` + ``callback=None``):

* realtime paces input at real-time speed and queues behind live sessions,
  giving 7-60s+ end-to-end for a 4s clip with frequent ``Idle timeout!``
* async file transcription completes a 4s clip in ~2-5s reliably.

The async API requires a publicly-reachable URL; the caller generates a
MinIO presigned URL and hands it in. See
``docs/phase2-step2-voice-intake.md §0.5.1``.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from http import HTTPStatus

import httpx

from app.config import settings

logger = logging.getLogger(__name__)


class SttUnavailableError(RuntimeError):
    """DashScope STT 暂不可用（上游 5xx / 网络 / SDK 异常 / 空文本）。"""


# Per-clip hard cap. DashScope's async transcription normally settles in
# a few seconds but can queue; beyond this we'd rather fail fast and let
# the user retry than sit on the socket.
_WAIT_TIMEOUT_SECONDS = 25


def _submit_and_wait(file_url: str) -> dict:
    """Call DashScope async transcription and block until it settles."""
    import dashscope
    from dashscope.audio.asr import Transcription

    if settings.DASHSCOPE_API_KEY:
        dashscope.api_key = settings.DASHSCOPE_API_KEY

    try:
        submit = Transcription.async_call(
            model=settings.DASHSCOPE_STT_MODEL,
            file_urls=[file_url],
            language_hints=["zh", "en"],
        )
    except Exception as e:
        logger.warning("dashscope stt submit exception: %s", e)
        raise SttUnavailableError(str(e)) from e

    status_code = getattr(submit, "status_code", None)
    if status_code != HTTPStatus.OK:
        message = getattr(submit, "message", "")
        logger.warning("dashscope stt submit non-200: %s %s", status_code, message)
        raise SttUnavailableError(f"submit HTTP {status_code}: {message}")

    output = getattr(submit, "output", None) or {}
    task_id = output.get("task_id") if isinstance(output, dict) else None
    if not task_id:
        raise SttUnavailableError("no task_id in submit response")

    try:
        result = Transcription.wait(task=task_id, timeout=_WAIT_TIMEOUT_SECONDS)
    except Exception as e:
        logger.warning("dashscope stt wait exception: %s", e)
        raise SttUnavailableError(str(e)) from e

    status_code = getattr(result, "status_code", None)
    if status_code != HTTPStatus.OK:
        message = getattr(result, "message", "")
        raise SttUnavailableError(f"wait HTTP {status_code}: {message}")

    out = getattr(result, "output", None)
    if isinstance(out, dict):
        return out
    # Some SDK versions wrap output in an attr-like object; coerce.
    return dict(out) if out is not None else {}


def _extract_transcript_url(output: dict) -> str:
    """The async API returns an S3-like JSON URL per input file. Pull it out."""
    task_status = output.get("task_status")
    if task_status != "SUCCEEDED":
        raise SttUnavailableError(f"task status {task_status!r}")

    results = output.get("results") or []
    if not results:
        raise SttUnavailableError("empty results array")

    first = results[0]
    sub_status = first.get("subtask_status")
    if sub_status and sub_status != "SUCCEEDED":
        code = first.get("code") or ""
        message = first.get("message") or ""
        raise SttUnavailableError(f"subtask {sub_status}: {code} {message}")

    url = first.get("transcription_url")
    if not url:
        raise SttUnavailableError("no transcription_url in result")
    return url


def _fetch_transcript_text(transcription_url: str) -> str:
    """Fetch and parse the per-file transcription JSON, joining sentence texts."""
    try:
        resp = httpx.get(transcription_url, timeout=10.0)
        resp.raise_for_status()
        doc = resp.json()
    except Exception as e:
        logger.warning("dashscope stt fetch transcript exception: %s", e)
        raise SttUnavailableError(f"fetch transcription: {e}") from e

    parts: list[str] = []
    for tr in doc.get("transcripts") or []:
        text = tr.get("text")
        if isinstance(text, str) and text.strip():
            parts.append(text.strip())
            continue
        # Fallback: concatenate per-sentence text if `text` is missing.
        for sent in tr.get("sentences") or []:
            t = sent.get("text") if isinstance(sent, dict) else None
            if isinstance(t, str) and t.strip():
                parts.append(t.strip())
    return " ".join(parts).strip()


def _transcribe_sync(file_url: str) -> str:
    output = _submit_and_wait(file_url)
    transcript_url = _extract_transcript_url(output)
    return _fetch_transcript_text(transcript_url)


async def transcribe(file_url: str) -> str:
    """Transcribe a remote audio URL via DashScope Paraformer (async file mode).

    `file_url` must be reachable from DashScope's servers (e.g. a MinIO
    presigned URL bound to the server's public host). Raises
    `SttUnavailableError` on upstream / network failure, malformed
    response, or when the model returned an empty string (product treats
    that as `status=stt_failed`, not an error).
    """
    if not settings.DASHSCOPE_API_KEY:
        raise SttUnavailableError("DASHSCOPE_API_KEY is not configured")

    t0 = time.perf_counter()
    try:
        text = await asyncio.to_thread(_transcribe_sync, file_url)
    except SttUnavailableError as e:
        dt = time.perf_counter() - t0
        logger.info("stt elapsed=%.2fs failed: %s", dt, e)
        raise
    dt = time.perf_counter() - t0
    logger.info("stt elapsed=%.2fs ok chars=%d", dt, len(text))
    if not text:
        raise SttUnavailableError("empty transcript")
    return text
