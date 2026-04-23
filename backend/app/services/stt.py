"""DashScope Paraformer / Fun-ASR STT thin wrapper.

Uses the **async file-transcription** API (``dashscope.audio.asr.Transcription``).
By default it hits the **Singapore** region with ``fun-asr``; if that key
is missing or the call fails we fall back to the **Beijing** region with
``paraformer-v1``.

Why two regions
---------------

The backend runs in Tokyo. Benchmark on 2026-04-21 (3.1s clip, N=10,
``scripts/stt_bench.py``) showed the Beijing DashScope endpoint's TLS
handshake alone taking ~3.2s and end-to-end p50 of 6.3s, versus
Singapore's 80ms handshake and p50 2.6s. The ``fun-asr`` model is only
available on the Beijing and Singapore regions; ``paraformer-v1`` stays
as a fallback because it's the only model whose Beijing-region
behaviour has been validated for this project.

See ``docs/phase2-step2-voice-intake.md §0.5.1``.
"""
from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from http import HTTPStatus

import httpx

from app.config import settings

logger = logging.getLogger(__name__)


class SttUnavailableError(RuntimeError):
    """DashScope STT 暂不可用（上游 5xx / 网络 / SDK 异常 / 空文本）。"""


# Per-clip hard cap, enforced on OUR side via `asyncio.wait_for`. The
# DashScope SDK's `Transcription.wait` signature accepts **kwargs but
# *ignores* any `timeout` we pass — internally it polls
# `task_status` with a 1→5s exponential backoff until the task hits a
# terminal state, with no upper bound. Benchmark on 2026-04-21 put SG
# p90 at 4.3s, but a production incident on 2026-04-23 observed a
# single clip blocked for 148s on a DashScope queue hiccup while we
# held the client socket open. Budgets here must fit comfortably under
# the Flutter client's 30s `receiveTimeout` even in the worst case
# (SG timeout → BJ timeout → return 503).
_SG_WAIT_TIMEOUT_SECONDS = 12
_BJ_WAIT_TIMEOUT_SECONDS = 12


@dataclass(frozen=True)
class _Region:
    label: str
    api_key: str
    base_url: str
    model: str
    wait_timeout: int


def _regions_in_priority_order() -> list[_Region]:
    """Return non-empty regions to try, primary first.

    Singapore is preferred (faster and more stable from the Tokyo host).
    Beijing is the fallback; if only one of the two keys is configured
    we return just that one.
    """
    out: list[_Region] = []
    if settings.DASHSCOPE_API_KEY_SAG:
        out.append(
            _Region(
                label="singapore",
                api_key=settings.DASHSCOPE_API_KEY_SAG,
                base_url=settings.DASHSCOPE_STT_BASE_URL,
                model=settings.DASHSCOPE_STT_MODEL,
                wait_timeout=_SG_WAIT_TIMEOUT_SECONDS,
            )
        )
    if settings.DASHSCOPE_API_KEY:
        out.append(
            _Region(
                label="beijing-fallback",
                api_key=settings.DASHSCOPE_API_KEY,
                base_url=settings.DASHSCOPE_STT_FALLBACK_BASE_URL,
                model=settings.DASHSCOPE_STT_FALLBACK_MODEL,
                wait_timeout=_BJ_WAIT_TIMEOUT_SECONDS,
            )
        )
    return out


def _submit_and_wait(file_url: str, region: _Region) -> dict:
    """Call DashScope async transcription and block until it settles."""
    import dashscope
    from dashscope.audio.asr import Transcription

    # The SDK reads these at call time, so setting them per-call is
    # enough — no need to snapshot/restore. We pin both so a stray
    # `DASHSCOPE_API_KEY` env var can't leak in via SDK auto-detection.
    dashscope.api_key = region.api_key
    dashscope.base_http_api_url = region.base_url

    try:
        submit = Transcription.async_call(
            model=region.model,
            file_urls=[file_url],
            language_hints=["zh", "en"],
        )
    except Exception as e:
        logger.warning("dashscope stt submit exception (%s): %s", region.label, e)
        raise SttUnavailableError(str(e)) from e

    status_code = getattr(submit, "status_code", None)
    if status_code != HTTPStatus.OK:
        message = getattr(submit, "message", "")
        logger.warning(
            "dashscope stt submit non-200 (%s): %s %s",
            region.label, status_code, message,
        )
        raise SttUnavailableError(f"submit HTTP {status_code}: {message}")

    output = getattr(submit, "output", None) or {}
    task_id = output.get("task_id") if isinstance(output, dict) else None
    if not task_id:
        raise SttUnavailableError("no task_id in submit response")

    try:
        # NOTE: `Transcription.wait` does NOT accept a timeout — any
        # kwarg passed here is dropped. Deadline enforcement happens
        # in the async caller via `asyncio.wait_for`.
        result = Transcription.wait(task=task_id)
    except Exception as e:
        logger.warning("dashscope stt wait exception (%s): %s", region.label, e)
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


def _transcribe_sync(file_url: str, region: _Region) -> str:
    output = _submit_and_wait(file_url, region)
    transcript_url = _extract_transcript_url(output)
    return _fetch_transcript_text(transcript_url)


async def transcribe(file_url: str) -> str:
    """Transcribe a remote audio URL via DashScope (async file mode).

    Tries the Singapore region first (``fun-asr``); on any
    ``SttUnavailableError`` or empty transcript it retries against the
    Beijing region (``paraformer-v1``). Raises ``SttUnavailableError``
    only when every configured region has failed — callers treat that
    as ``status=stt_failed`` (not a 5xx).

    `file_url` must be reachable from DashScope's servers (e.g. a MinIO
    presigned URL bound to the server's public host).
    """
    regions = _regions_in_priority_order()
    if not regions:
        raise SttUnavailableError(
            "neither DASHSCOPE_API_KEY_SAG nor DASHSCOPE_API_KEY is configured"
        )

    last_error: SttUnavailableError | None = None
    for region in regions:
        t0 = time.perf_counter()
        try:
            text = await asyncio.wait_for(
                asyncio.to_thread(_transcribe_sync, file_url, region),
                timeout=region.wait_timeout,
            )
        except asyncio.TimeoutError:
            dt = time.perf_counter() - t0
            # The worker thread keeps polling DashScope in the
            # background — we can't cancel `asyncio.to_thread`. It
            # exits on its own once the task settles; no resource we
            # care about is leaked beyond that one thread slot.
            logger.info(
                "stt region=%s model=%s elapsed=%.2fs timed out",
                region.label, region.model, dt,
            )
            last_error = SttUnavailableError(f"wait timeout after {region.wait_timeout}s")
            continue
        except SttUnavailableError as e:
            dt = time.perf_counter() - t0
            logger.info(
                "stt region=%s model=%s elapsed=%.2fs failed: %s",
                region.label, region.model, dt, e,
            )
            last_error = e
            continue

        dt = time.perf_counter() - t0
        if not text:
            logger.info(
                "stt region=%s model=%s elapsed=%.2fs empty transcript",
                region.label, region.model, dt,
            )
            last_error = SttUnavailableError("empty transcript")
            continue

        logger.info(
            "stt region=%s model=%s elapsed=%.2fs ok chars=%d",
            region.label, region.model, dt, len(text),
        )
        return text

    assert last_error is not None  # loop guarantees at least one attempt
    raise last_error
