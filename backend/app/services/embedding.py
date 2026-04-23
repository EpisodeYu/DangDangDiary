"""DashScope multi-modal embedding wrapper (Phase 2 Step 3).

Calls ``dashscope.MultiModalEmbedding.call`` against the **Singapore**
region by default. The multi-modal independent-vector API is *not*
available through DashScope's OpenAI-compatible endpoint — only the
native ``/api/v1`` route, accessible via the ``dashscope`` SDK (see
docs/API_docs/多模态向量化,md §168). We therefore don't reuse the
``openai.AsyncOpenAI`` plumbing that the Step 2 LLM path uses.

Why Singapore
-------------

Mirrors the region reasoning in ``app/services/stt.py`` /
``app/services/llm.py``: the backend sits in Tokyo, and the TLS
handshake to ``dashscope-intl.aliyuncs.com`` (Singapore) is ~40× faster
than to ``dashscope.aliyuncs.com`` (Beijing). For a 5-photo classify
request that difference pushes the p99 well under 1s.

The Singapore model is ``tongyi-embedding-vision-plus`` (1152 dim,
fixed — the newer ``-2026-03-06`` dated variant with selectable 1024
dim was still Beijing-only at the time of implementation, 2026-04-21).
The exact model is overridable via ``DASHSCOPE_EMBEDDING_MODEL``.

If the primary (Singapore) call fails — missing key, 5xx, malformed
output — we fall back to the Beijing region only when a Beijing key is
configured. Callers see a single ``EmbeddingUnavailableError`` when
everything has failed so the classify endpoint can return soft nulls
rather than 5xx.
"""
from __future__ import annotations

import asyncio
import base64
import io
import logging
import time
from dataclasses import dataclass
from http import HTTPStatus

from PIL import Image

from app.config import settings


logger = logging.getLogger(__name__)


class EmbeddingUnavailableError(RuntimeError):
    """DashScope embedding upstream is unreachable / over-quota / malformed."""


# Global concurrency gate on the DashScope SDK call path. The SDK is
# blocking and is dispatched via ``asyncio.to_thread``; without this
# gate a 5-photo classify burst + 5-photo upload backfill can pin up
# to 10 threads at once, starving everything else in the process
# (see 2026-04-22 root-cause: upload progress bar crawling while
# classify runs in parallel).
#
# Created lazily because ``asyncio.Semaphore`` binds to the running
# event loop at construction time — building it at module import would
# attach it to whatever loop FastAPI happened to have around (often a
# loop that gets replaced during test setup, surfacing as the
# ``got Future <Future pending> attached to a different loop`` error).
# Lazy construction per loop sidesteps that entirely.
_dashscope_semaphores: dict[int, asyncio.Semaphore] = {}


def _get_dashscope_semaphore() -> asyncio.Semaphore:
    loop = asyncio.get_event_loop()
    key = id(loop)
    sem = _dashscope_semaphores.get(key)
    if sem is None:
        limit = max(1, int(settings.DASHSCOPE_EMBEDDING_CONCURRENCY))
        sem = asyncio.Semaphore(limit)
        _dashscope_semaphores[key] = sem
    return sem


# Long-side compression target. Singapore-region
# `tongyi-embedding-vision-plus` accepts images up to 3 MB; 512 px JPEG-85
# lands at ~70 KB and empirically preserves the features that separate
# individual pets (fur pattern, face geometry).
_MAX_SIDE_PX = 512
_JPEG_QUALITY = 85


@dataclass(frozen=True)
class _Region:
    label: str
    api_key: str
    base_url: str


def _regions_in_priority_order() -> list[_Region]:
    """Return non-empty regions to try, primary first.

    Singapore first (see module docstring). Beijing is only attempted
    if a Beijing key is configured AND it's different from the SG key.
    """
    out: list[_Region] = []
    if settings.DASHSCOPE_API_KEY_SAG:
        out.append(_Region(
            label="singapore",
            api_key=settings.DASHSCOPE_API_KEY_SAG,
            base_url=settings.DASHSCOPE_EMBEDDING_BASE_URL,
        ))
    if settings.DASHSCOPE_API_KEY and (
        not settings.DASHSCOPE_API_KEY_SAG
        or settings.DASHSCOPE_API_KEY != settings.DASHSCOPE_API_KEY_SAG
    ):
        out.append(_Region(
            label="beijing-fallback",
            api_key=settings.DASHSCOPE_API_KEY,
            base_url=settings.DASHSCOPE_EMBEDDING_FALLBACK_BASE_URL,
        ))
    return out


def _compress_to_data_uri(image_bytes: bytes) -> str:
    """Downscale + re-encode to a ``data:image/jpeg;base64,...`` URI.

    Upsampling is intentionally skipped — passing a 128 px picture at
    512 px just wastes tokens and adds edge-blur that hurts the
    embedding slightly.
    """
    with Image.open(io.BytesIO(image_bytes)) as im:
        im = im.convert("RGB")
        w, h = im.size
        long_side = max(w, h)
        if long_side > _MAX_SIDE_PX:
            scale = _MAX_SIDE_PX / long_side
            new_size = (max(1, int(w * scale)), max(1, int(h * scale)))
            im = im.resize(new_size, Image.LANCZOS)
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=_JPEG_QUALITY)
    b64 = base64.b64encode(buf.getvalue()).decode("ascii")
    return f"data:image/jpeg;base64,{b64}"


def _call_dashscope_sync(data_uri: str, region: _Region) -> list[float]:
    """Run the blocking SDK call against a single region. Raises on any error."""
    import dashscope
    from dashscope import MultiModalEmbedding

    # SDK reads these at call time, so per-call assignment is enough.
    # Pin both to defend against ambient `DASHSCOPE_API_KEY` env leakage.
    dashscope.api_key = region.api_key
    dashscope.base_http_api_url = region.base_url

    try:
        # `dimension` is only honoured by the `-2026-03-06` variants.
        # On the default SG model (``tongyi-embedding-vision-plus``) the
        # server ignores unknown kwargs silently — we still send it so
        # a future model swap via `.env` picks the correct width
        # automatically.
        result = MultiModalEmbedding.call(
            model=settings.DASHSCOPE_EMBEDDING_MODEL,
            input=[{"image": data_uri}],
            dimension=settings.DASHSCOPE_EMBEDDING_DIMENSION,
        )
    except Exception as e:  # dashscope raises plain Exceptions on network faults
        raise EmbeddingUnavailableError(f"{region.label} sdk exception: {e}") from e

    status = getattr(result, "status_code", None)
    if status != HTTPStatus.OK:
        message = getattr(result, "message", "")
        raise EmbeddingUnavailableError(
            f"{region.label} http {status}: {message}"
        )

    output = getattr(result, "output", None) or {}
    # Response shape (both vision-plus variants):
    #   {"embeddings": [{"type": "image", "embedding": [...], "index": 0}], ...}
    try:
        items = output["embeddings"]
        vec = items[0]["embedding"]
    except (KeyError, IndexError, TypeError) as e:
        raise EmbeddingUnavailableError(
            f"{region.label} bad response shape: {output!r}"
        ) from e

    if not isinstance(vec, list) or not vec:
        raise EmbeddingUnavailableError(
            f"{region.label} empty embedding: {vec!r}"
        )
    if len(vec) != settings.DASHSCOPE_EMBEDDING_DIMENSION:
        raise EmbeddingUnavailableError(
            f"{region.label} unexpected dim {len(vec)}, "
            f"expected {settings.DASHSCOPE_EMBEDDING_DIMENSION}. "
            f"Check DASHSCOPE_EMBEDDING_MODEL="
            f"{settings.DASHSCOPE_EMBEDDING_MODEL}"
        )
    return [float(x) for x in vec]


async def embed_image(image_bytes: bytes) -> list[float]:
    """Return the (D,) embedding for one image.

    Raises :class:`EmbeddingUnavailableError` if *every* configured
    region fails. The caller is expected to soft-fail into
    ``pet_id=null`` rather than surface a 5xx.
    """
    regions = _regions_in_priority_order()
    if not regions:
        raise EmbeddingUnavailableError(
            "neither DASHSCOPE_API_KEY_SAG nor DASHSCOPE_API_KEY configured"
        )

    # Compress once, not per region — the payload is identical.
    data_uri = await asyncio.to_thread(_compress_to_data_uri, image_bytes)

    last_err: EmbeddingUnavailableError | None = None
    sem = _get_dashscope_semaphore()
    for region in regions:
        # Wait time inside the semaphore is tracked separately so slow
        # p99 calls don't silently bloat the "elapsed" metric the
        # caller monitors for upstream health. Useful when diagnosing
        # "is DashScope slow or are we just queued?".
        t_wait = time.perf_counter()
        async with sem:
            wait_s = time.perf_counter() - t_wait
            t0 = time.perf_counter()
            try:
                vec = await asyncio.to_thread(
                    _call_dashscope_sync, data_uri, region,
                )
            except EmbeddingUnavailableError as e:
                dt = time.perf_counter() - t0
                logger.info(
                    "embedding region=%s wait=%.2fs elapsed=%.2fs failed: %s",
                    region.label, wait_s, dt, e,
                )
                last_err = e
                continue

            dt = time.perf_counter() - t0
            logger.info(
                "embedding region=%s wait=%.2fs elapsed=%.2fs ok dim=%d",
                region.label, wait_s, dt, len(vec),
            )
            return vec

    assert last_err is not None  # loop guarantees at least one attempt
    raise last_err
