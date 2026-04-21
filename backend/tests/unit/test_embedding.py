"""Unit tests for ``app.services.embedding``.

The real DashScope SDK is monkey-patched at the ``MultiModalEmbedding.call``
boundary so no network traffic ever leaves the test process — we only
verify the shape of what our code passes in and how it interprets the
result.
"""
from __future__ import annotations

import base64
import io
from http import HTTPStatus

import pytest
from PIL import Image

from app.config import settings
from app.services import embedding as embedding_mod


# Most tests here hit an async path; mark the async ones individually
# instead of via `pytestmark` so the pure-sync compress tests don't
# emit the "async mark on sync fn" warning.
_aio = pytest.mark.asyncio


# --------------------------------------------------------- fixtures


class _FakeResult:
    """Mimics the attributes the service reads off a real dashscope Result."""

    def __init__(
        self,
        *,
        status_code: int = HTTPStatus.OK,
        output: dict | None = None,
        message: str = "",
    ) -> None:
        self.status_code = status_code
        self.output = output if output is not None else {
            "embeddings": [
                {
                    "type": "image",
                    "embedding": [0.01] * settings.DASHSCOPE_EMBEDDING_DIMENSION,
                    "index": 0,
                }
            ]
        }
        self.message = message


def _png_bytes(w: int, h: int, color: tuple[int, int, int] = (200, 100, 50)) -> bytes:
    """Emit a trivially-parseable PNG image for the compress helper."""
    buf = io.BytesIO()
    Image.new("RGB", (w, h), color).save(buf, format="PNG")
    return buf.getvalue()


# --------------------------------------------------------- compress


def test_compress_long_side_downscaled_and_returns_jpeg_data_uri():
    src = _png_bytes(2000, 1000)
    uri = embedding_mod._compress_to_data_uri(src)

    assert uri.startswith("data:image/jpeg;base64,")
    raw = base64.b64decode(uri.split(",", 1)[1])
    with Image.open(io.BytesIO(raw)) as im:
        w, h = im.size
        assert max(w, h) == embedding_mod._MAX_SIDE_PX
        # Aspect ratio preserved within rounding.
        assert abs((w / h) - 2.0) < 0.05
        assert im.format == "JPEG"


def test_compress_small_image_not_upscaled():
    src = _png_bytes(128, 64)
    uri = embedding_mod._compress_to_data_uri(src)

    raw = base64.b64decode(uri.split(",", 1)[1])
    with Image.open(io.BytesIO(raw)) as im:
        assert im.size == (128, 64)


def test_compress_non_rgb_mode_converts_to_rgb():
    # RGBA + palette mode images both must round-trip through RGB or
    # Pillow's JPEG encoder raises OSError.
    rgba = io.BytesIO()
    Image.new("RGBA", (200, 200), (10, 20, 30, 255)).save(rgba, format="PNG")
    uri = embedding_mod._compress_to_data_uri(rgba.getvalue())
    raw = base64.b64decode(uri.split(",", 1)[1])
    with Image.open(io.BytesIO(raw)) as im:
        assert im.mode == "RGB"


# ---------------------------------------------------- embed_image


@_aio
async def test_embed_image_calls_sdk_with_expected_kwargs(monkeypatch):
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY_SAG", "sk-sg-test")
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY", "")

    captured_kwargs: dict = {}

    def _fake_call(**kwargs):
        captured_kwargs.update(kwargs)
        return _FakeResult()

    monkeypatch.setattr(
        "dashscope.MultiModalEmbedding.call", staticmethod(_fake_call),
    )

    vec = await embedding_mod.embed_image(_png_bytes(256, 256))
    assert len(vec) == settings.DASHSCOPE_EMBEDDING_DIMENSION

    assert captured_kwargs["model"] == settings.DASHSCOPE_EMBEDDING_MODEL
    assert captured_kwargs["dimension"] == settings.DASHSCOPE_EMBEDDING_DIMENSION
    # Input must be a list-of-dict with the base64 data URI (NOT a public URL).
    inp = captured_kwargs["input"]
    assert isinstance(inp, list) and len(inp) == 1
    assert inp[0]["image"].startswith("data:image/jpeg;base64,")


@_aio
async def test_embed_image_raises_on_non_200(monkeypatch):
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY_SAG", "sk-sg")
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY", "")

    def _fake_call(**_):
        return _FakeResult(status_code=500, message="server error")

    monkeypatch.setattr(
        "dashscope.MultiModalEmbedding.call", staticmethod(_fake_call),
    )

    with pytest.raises(embedding_mod.EmbeddingUnavailableError):
        await embedding_mod.embed_image(_png_bytes(64, 64))


@_aio
async def test_embed_image_raises_on_bad_shape(monkeypatch):
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY_SAG", "sk-sg")
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY", "")

    def _fake_call(**_):
        return _FakeResult(output={"unexpected": True})

    monkeypatch.setattr(
        "dashscope.MultiModalEmbedding.call", staticmethod(_fake_call),
    )

    with pytest.raises(embedding_mod.EmbeddingUnavailableError):
        await embedding_mod.embed_image(_png_bytes(64, 64))


@_aio
async def test_embed_image_raises_on_wrong_dim(monkeypatch):
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY_SAG", "sk-sg")
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY", "")

    def _fake_call(**_):
        return _FakeResult(output={
            "embeddings": [
                {"type": "image", "embedding": [0.1] * 64, "index": 0}
            ],
        })

    monkeypatch.setattr(
        "dashscope.MultiModalEmbedding.call", staticmethod(_fake_call),
    )

    with pytest.raises(embedding_mod.EmbeddingUnavailableError):
        await embedding_mod.embed_image(_png_bytes(64, 64))


@_aio
async def test_embed_image_raises_without_any_key(monkeypatch):
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY_SAG", "")
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY", "")

    with pytest.raises(embedding_mod.EmbeddingUnavailableError):
        await embedding_mod.embed_image(_png_bytes(64, 64))


@_aio
async def test_embed_image_falls_back_to_beijing_on_sg_failure(monkeypatch):
    """SG returns 5xx, Beijing key is set → second call succeeds."""
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY_SAG", "sk-sg")
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY", "sk-bj")

    calls: list[str] = []

    def _fake_call(**kwargs):
        # The service pins `dashscope.api_key` right before each call,
        # so we read it here to prove which region is being used.
        import dashscope
        calls.append(dashscope.api_key)
        if dashscope.api_key == "sk-sg":
            return _FakeResult(status_code=500, message="sg boom")
        return _FakeResult()

    monkeypatch.setattr(
        "dashscope.MultiModalEmbedding.call", staticmethod(_fake_call),
    )

    vec = await embedding_mod.embed_image(_png_bytes(64, 64))
    assert len(vec) == settings.DASHSCOPE_EMBEDDING_DIMENSION
    assert calls == ["sk-sg", "sk-bj"]


@_aio
async def test_embed_image_singapore_preferred_when_same_key(monkeypatch):
    """Unified single key: SG route must still be picked first."""
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY_SAG", "sk-same")
    monkeypatch.setattr(settings, "DASHSCOPE_API_KEY", "sk-same")

    base_urls: list[str] = []

    def _fake_call(**_):
        import dashscope
        base_urls.append(dashscope.base_http_api_url)
        return _FakeResult()

    monkeypatch.setattr(
        "dashscope.MultiModalEmbedding.call", staticmethod(_fake_call),
    )

    await embedding_mod.embed_image(_png_bytes(64, 64))
    # Exactly one call — no BJ fallback when both keys match — and it
    # targeted the Singapore endpoint.
    assert len(base_urls) == 1
    assert "dashscope-intl" in base_urls[0]
