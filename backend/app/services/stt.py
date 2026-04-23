"""DashScope STT thin wrapper.

Two transcription paths, tried in order:

1. **Primary — DashScope Singapore ``fun-asr-realtime`` via WebSocket
   streaming.** Takes raw audio bytes, parses the WAV header, streams
   the PCM frames through the ``dashscope.audio.asr.Recognition``
   duplex API, and blocks on ``stop()`` until the server flushes the
   final sentence-end result. Benchmark on **2026-04-23** (3.1s 16kHz
   mono WAV × N=10, Tokyo host) showed p50 **1.26s**, p90 1.59s, max
   1.61s, 10/10 success. See ``backend/scripts/stt_realtime_bench.py``.

2. **Fallback — DashScope Beijing ``paraformer-v1`` via the async
   file-transcription API.** Takes the MinIO presigned URL
   (DashScope fetches the audio itself). Benchmark p50 4.14s, max
   ~7s. Slower than the primary but has been stable across both the
   2026-04-21 and 2026-04-23 runs; kept as the safety net for when
   the WS path times out or the SG key isn't configured.

Why not the previous ``fun-asr`` *async* path on Singapore? As of
2026-04-23 the SG async queue is stuck in ``PENDING`` for 20s+ on
every request — 100% of production intakes hit the 12s timeout. The
realtime model on the same SG endpoint returns in <2s because it
bypasses the batch queue. See ``docs/phase2-step2-voice-intake.md
§0.5.1`` for the full history.
"""
from __future__ import annotations

import asyncio
import io
import logging
import time
import wave
from dataclasses import dataclass
from http import HTTPStatus

import httpx

from app.config import settings

logger = logging.getLogger(__name__)


class SttUnavailableError(RuntimeError):
    """DashScope STT 暂不可用（上游 5xx / 网络 / SDK 异常 / 空文本）。"""


# ----------------------------------------------------------------- consts

# DashScope WebSocket endpoints for the realtime / duplex models.
_WS_URL_SG = "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference"
_WS_URL_BJ = "wss://dashscope.aliyuncs.com/api-ws/v1/inference"

# DashScope HTTP endpoints for the async file-transcription fallback.
_HTTP_URL_BJ = "https://dashscope.aliyuncs.com/api/v1"

# Realtime path hard caps, enforced on our side via `asyncio.wait_for`.
# Benchmark p90 on 2026-04-23 is 1.59s; 6s is comfortable headroom for
# TLS + one-off network hiccups while staying well under the Flutter
# receiveTimeout (30s).
_SG_REALTIME_TIMEOUT_SECONDS = 6

# Async file-transcription path: `Transcription.wait` polls internally
# without a deadline, so we enforce one ourselves. Benchmark on
# 2026-04-23 shows BJ paraformer-v1 p90 ~6.5s; 12s catches the long
# tail (incidentally matches the pre-change value for continuity).
_BJ_ASYNC_TIMEOUT_SECONDS = 12

# 100ms of 16kHz mono 16-bit PCM = 3200 bytes. Matches the chunk size
# DashScope's own docs use in the realtime example loop.
_REALTIME_CHUNK_BYTES = 3200


# ---------------------------------------------------- WAV → PCM helper

def _extract_pcm(audio_bytes: bytes) -> tuple[bytes, int] | None:
    """Return ``(pcm_bytes, sample_rate)`` if the bytes are a 16-bit mono
    PCM WAV file; ``None`` otherwise.

    We use the stdlib ``wave`` module rather than blindly stripping 44
    bytes because:
    * Some WAV writers insert a ``LIST`` / ``INFO`` chunk before
      ``data``, making the header variable-length.
    * We want to refuse unexpected formats (stereo / 8-bit / 24-bit /
      24kHz) early and fall back to the async path, where DashScope
      does its own resampling.
    """
    try:
        with wave.open(io.BytesIO(audio_bytes), "rb") as wf:
            if wf.getsampwidth() != 2 or wf.getnchannels() != 1:
                return None
            sample_rate = wf.getframerate()
            if sample_rate not in (8000, 16000):
                return None
            pcm = wf.readframes(wf.getnframes())
    except (wave.Error, EOFError, ValueError):
        return None
    if not pcm:
        return None
    return pcm, sample_rate


# ------------------------------------------------------ realtime path

def _transcribe_realtime_sync(
    *,
    api_key: str,
    ws_url: str,
    model: str,
    pcm: bytes,
    sample_rate: int,
) -> str:
    """Run one WebSocket streaming transcription end-to-end.

    Blocks the calling thread until ``recognition.stop()`` returns —
    that's the signal from the server that the final sentence-end
    result has been flushed. Raises ``SttUnavailableError`` on SDK /
    network / server errors so the outer loop can fall back cleanly.
    """
    import dashscope
    from dashscope.audio.asr import (  # type: ignore[attr-defined]
        Recognition,
        RecognitionCallback,
        RecognitionResult,
    )

    dashscope.api_key = api_key
    dashscope.base_websocket_api_url = ws_url

    captured: list[str] = []
    error_box: list[str] = []

    class _CB(RecognitionCallback):  # type: ignore[misc]
        def on_error(self, message) -> None:  # type: ignore[override]
            # `message` is a RecognitionResult-like object with
            # `.request_id` / `.message` attrs. Stringify defensively.
            error_box.append(
                str(getattr(message, "message", None) or message)
            )

        def on_event(self, result) -> None:  # type: ignore[override]
            sent = result.get_sentence()
            if isinstance(sent, dict) and "text" in sent:
                if RecognitionResult.is_sentence_end(sent):
                    text = sent.get("text")
                    if isinstance(text, str) and text.strip():
                        captured.append(text.strip())

    recognition = Recognition(
        model=model,
        format="pcm",
        sample_rate=sample_rate,
        callback=_CB(),
    )

    try:
        recognition.start()
    except Exception as e:  # noqa: BLE001 — SDK throws all-sorts
        raise SttUnavailableError(f"realtime start failed: {e}") from e

    try:
        offset = 0
        while offset < len(pcm):
            n = min(_REALTIME_CHUNK_BYTES, len(pcm) - offset)
            recognition.send_audio_frame(pcm[offset:offset + n])
            offset += n
        recognition.stop()
    except Exception as e:  # noqa: BLE001
        raise SttUnavailableError(f"realtime stream failed: {e}") from e

    if error_box:
        raise SttUnavailableError(error_box[0])
    return "".join(captured).strip()


async def _transcribe_via_realtime(pcm: bytes, sample_rate: int) -> str:
    """Run the SG realtime path with a wall-clock timeout."""
    return await asyncio.wait_for(
        asyncio.to_thread(
            _transcribe_realtime_sync,
            api_key=settings.DASHSCOPE_API_KEY_SAG,
            ws_url=_WS_URL_SG,
            model="fun-asr-realtime",
            pcm=pcm,
            sample_rate=sample_rate,
        ),
        timeout=_SG_REALTIME_TIMEOUT_SECONDS,
    )


# ------------------------------------------- async file-transcription path

@dataclass(frozen=True)
class _AsyncRegion:
    label: str
    api_key: str
    base_url: str
    model: str


def _async_fallback_region() -> _AsyncRegion | None:
    """Return the Beijing fallback region descriptor, or None if unset."""
    if not settings.DASHSCOPE_API_KEY:
        return None
    return _AsyncRegion(
        label="beijing-fallback",
        api_key=settings.DASHSCOPE_API_KEY,
        base_url=_HTTP_URL_BJ,
        model="paraformer-v1",
    )


def _submit_and_wait(file_url: str, region: _AsyncRegion) -> dict:
    """Call DashScope async transcription and block until it settles."""
    import dashscope
    from dashscope.audio.asr import Transcription

    dashscope.api_key = region.api_key
    dashscope.base_http_api_url = region.base_url

    try:
        submit = Transcription.async_call(
            model=region.model,
            file_urls=[file_url],
            language_hints=["zh", "en"],
        )
    except Exception as e:
        logger.warning("async stt submit exception (%s): %s", region.label, e)
        raise SttUnavailableError(str(e)) from e

    status_code = getattr(submit, "status_code", None)
    if status_code != HTTPStatus.OK:
        message = getattr(submit, "message", "")
        logger.warning(
            "async stt submit non-200 (%s): %s %s",
            region.label, status_code, message,
        )
        raise SttUnavailableError(f"submit HTTP {status_code}: {message}")

    output = getattr(submit, "output", None) or {}
    task_id = output.get("task_id") if isinstance(output, dict) else None
    if not task_id:
        raise SttUnavailableError("no task_id in submit response")

    try:
        # `Transcription.wait` ignores any kwarg `timeout` we pass —
        # the outer `asyncio.wait_for` is the real deadline.
        result = Transcription.wait(task=task_id)
    except Exception as e:
        logger.warning("async stt wait exception (%s): %s", region.label, e)
        raise SttUnavailableError(str(e)) from e

    status_code = getattr(result, "status_code", None)
    if status_code != HTTPStatus.OK:
        message = getattr(result, "message", "")
        raise SttUnavailableError(f"wait HTTP {status_code}: {message}")

    out = getattr(result, "output", None)
    if isinstance(out, dict):
        return out
    return dict(out) if out is not None else {}


def _extract_transcript_url(output: dict) -> str:
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
    try:
        resp = httpx.get(transcription_url, timeout=10.0)
        resp.raise_for_status()
        doc = resp.json()
    except Exception as e:
        logger.warning("async stt fetch transcript exception: %s", e)
        raise SttUnavailableError(f"fetch transcription: {e}") from e

    parts: list[str] = []
    for tr in doc.get("transcripts") or []:
        text = tr.get("text")
        if isinstance(text, str) and text.strip():
            parts.append(text.strip())
            continue
        for sent in tr.get("sentences") or []:
            t = sent.get("text") if isinstance(sent, dict) else None
            if isinstance(t, str) and t.strip():
                parts.append(t.strip())
    return " ".join(parts).strip()


def _transcribe_async_sync(file_url: str, region: _AsyncRegion) -> str:
    output = _submit_and_wait(file_url, region)
    transcript_url = _extract_transcript_url(output)
    return _fetch_transcript_text(transcript_url)


async def _transcribe_via_async(file_url: str, region: _AsyncRegion) -> str:
    """Run the BJ async-file path with a wall-clock timeout."""
    return await asyncio.wait_for(
        asyncio.to_thread(_transcribe_async_sync, file_url, region),
        timeout=_BJ_ASYNC_TIMEOUT_SECONDS,
    )


# ------------------------------------------------------------- public

async def transcribe(
    *,
    audio_bytes: bytes,
    mime: str,
    audio_url: str,
) -> str:
    """Transcribe one voice-intake audio clip.

    ``audio_bytes``   the raw upload (used by the realtime WS path).
    ``mime``          the request's Content-Type; decides realtime-eligibility.
    ``audio_url``     MinIO presigned URL (used by the async fallback only).

    Raises ``SttUnavailableError`` when every configured path has
    failed; the caller treats that as ``status=stt_failed`` (not a 5xx).
    """

    last_error: SttUnavailableError | None = None

    # ---------- Primary: SG fun-asr-realtime via WebSocket ----------
    #
    # Only WAV is streamed through the realtime API — it's what the
    # Flutter client records today, and decoding m4a/mp3 on the hot
    # path would cost more than the fallback saves. Other formats fall
    # straight through to the async-file path.
    if settings.DASHSCOPE_API_KEY_SAG and mime.lower() in {
        "audio/wav", "audio/x-wav",
    }:
        pcm_info = _extract_pcm(audio_bytes)
        if pcm_info is None:
            logger.info(
                "stt skip realtime: wav parse rejected "
                "(expected 16-bit mono @ 8k/16k)",
            )
        else:
            pcm, sample_rate = pcm_info
            t0 = time.perf_counter()
            try:
                text = await _transcribe_via_realtime(pcm, sample_rate)
            except asyncio.TimeoutError:
                dt = time.perf_counter() - t0
                logger.info(
                    "stt sg-realtime elapsed=%.2fs timed out", dt,
                )
                last_error = SttUnavailableError(
                    f"sg-realtime timeout after {_SG_REALTIME_TIMEOUT_SECONDS}s"
                )
            except SttUnavailableError as e:
                dt = time.perf_counter() - t0
                logger.info(
                    "stt sg-realtime elapsed=%.2fs failed: %s", dt, e,
                )
                last_error = e
            else:
                dt = time.perf_counter() - t0
                if text:
                    logger.info(
                        "stt sg-realtime elapsed=%.2fs ok chars=%d",
                        dt, len(text),
                    )
                    return text
                logger.info(
                    "stt sg-realtime elapsed=%.2fs empty transcript", dt,
                )
                last_error = SttUnavailableError("sg-realtime empty transcript")

    # ---------- Fallback: BJ paraformer-v1 async-file ----------
    region = _async_fallback_region()
    if region is not None:
        t0 = time.perf_counter()
        try:
            text = await _transcribe_via_async(audio_url, region)
        except asyncio.TimeoutError:
            dt = time.perf_counter() - t0
            logger.info(
                "stt region=%s model=%s elapsed=%.2fs timed out",
                region.label, region.model, dt,
            )
            last_error = SttUnavailableError(
                f"async-file timeout after {_BJ_ASYNC_TIMEOUT_SECONDS}s"
            )
        except SttUnavailableError as e:
            dt = time.perf_counter() - t0
            logger.info(
                "stt region=%s model=%s elapsed=%.2fs failed: %s",
                region.label, region.model, dt, e,
            )
            last_error = e
        else:
            dt = time.perf_counter() - t0
            if text:
                logger.info(
                    "stt region=%s model=%s elapsed=%.2fs ok chars=%d",
                    region.label, region.model, dt, len(text),
                )
                return text
            logger.info(
                "stt region=%s model=%s elapsed=%.2fs empty transcript",
                region.label, region.model, dt,
            )
            last_error = SttUnavailableError("empty transcript")

    if last_error is None:
        raise SttUnavailableError(
            "neither DASHSCOPE_API_KEY_SAG nor DASHSCOPE_API_KEY is configured"
        )
    raise last_error
