"""DashScope Paraformer STT thin wrapper.

We deliberately use the realtime model (`paraformer-realtime-v2`) in its
synchronous-file mode (`callback=None`) rather than the async
`paraformer-v2`: async returns a `task_id` and takes 10-30s to complete,
which blows the 1-2s UX budget for voice intake. See docs
phase2-step2-voice-intake.md §0.5.1.
"""
from __future__ import annotations

import asyncio
import logging
from http import HTTPStatus

from app.config import settings

logger = logging.getLogger(__name__)


class SttUnavailableError(RuntimeError):
    """DashScope STT 暂不可用（上游 5xx / 网络 / SDK 异常 / 空文本）。"""


# MIME → DashScope SDK `format` argument. The SDK only understands a
# small set of format names; keep this map narrow and validate upstream.
_FORMAT_MAP = {
    "audio/m4a": "m4a",
    "audio/x-m4a": "m4a",
    "audio/mp4": "m4a",
    "audio/aac": "aac",
    "audio/mpeg": "mp3",
    "audio/mp3": "mp3",
    "audio/wav": "wav",
    "audio/x-wav": "wav",
}


def _transcribe_sync(audio_path: str, fmt: str) -> str:
    """Actually call the DashScope SDK. Kept sync so we can dispatch it
    to a worker thread from the async request path."""
    # Import lazily so unit tests can monkeypatch without needing the
    # package installed on every CI runner.
    import dashscope
    from dashscope.audio.asr import Recognition

    # Ensure the api_key is set each call — the settings object may have
    # been overridden in tests even if `import dashscope` ran at import
    # time with an empty key.
    if settings.DASHSCOPE_API_KEY:
        dashscope.api_key = settings.DASHSCOPE_API_KEY

    recognition = Recognition(
        model=settings.DASHSCOPE_STT_MODEL,
        format=fmt,
        sample_rate=16000,
        language_hints=["zh", "en"],
        disfluency_removal_enabled=True,
        callback=None,
    )

    try:
        result = recognition.call(audio_path)
    except Exception as e:  # SDK 内部网络 / 超时异常
        logger.warning("dashscope stt exception: %s", e)
        raise SttUnavailableError(str(e)) from e

    status_code = getattr(result, "status_code", None)
    if status_code != HTTPStatus.OK:
        message = getattr(result, "message", "")
        logger.warning("dashscope stt non-200: %s %s", status_code, message)
        raise SttUnavailableError(f"HTTP {status_code}: {message}")

    # SDK versions differ: some return list[dict], some list[Sentence]
    # with a `.text` attribute, some just a str. Handle all three.
    sentences = result.get_sentence() or []
    if isinstance(sentences, str):
        text = sentences.strip()
    else:
        parts: list[str] = []
        for s in sentences:
            if isinstance(s, dict):
                parts.append(s.get("text", ""))
            else:
                parts.append(getattr(s, "text", "") or "")
        text = " ".join(p for p in parts if p).strip()

    return text


async def transcribe(audio_path: str, mime: str) -> str:
    """Transcribe a local audio file via DashScope Paraformer (sync mode).

    Raises `SttUnavailableError` on upstream / network failure, malformed
    response, or when the model returned an empty string (which the
    product treats as `status=stt_failed` rather than an error).
    """
    fmt = _FORMAT_MAP.get(mime.lower())
    if fmt is None:
        raise SttUnavailableError(f"unsupported mime {mime!r}")
    if not settings.DASHSCOPE_API_KEY:
        raise SttUnavailableError("DASHSCOPE_API_KEY is not configured")

    text = await asyncio.to_thread(_transcribe_sync, audio_path, fmt)
    if not text:
        raise SttUnavailableError("empty transcript")
    return text
