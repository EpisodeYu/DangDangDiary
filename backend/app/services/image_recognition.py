import io
import logging
import threading
from typing import TypedDict

from PIL import Image

from app.config import settings

logger = logging.getLogger(__name__)

PET_KEYWORDS = {
    "cat", "kitten", "kitty", "feline",
    "dog", "puppy", "canine", "hound",
    "猫", "小猫", "猫咪", "犬", "狗", "小狗", "宠物", "pet",
}

CONFIDENCE_THRESHOLD = 0.3

RECOGNITION_MAX_SIZE = (800, 800)
RECOGNITION_JPEG_QUALITY = 70

_thread_local = threading.local()


class ImageRecognitionResult(TypedDict):
    is_pet: bool
    labels: list[str]
    skipped: bool


def _is_configured() -> bool:
    return bool(settings.ALIYUN_ACCESS_KEY_ID and settings.ALIYUN_ACCESS_KEY_SECRET)


def _get_client():
    """Return a thread-local Aliyun ImageRecog client to avoid contention
    when multiple threads call the SDK concurrently."""
    client = getattr(_thread_local, 'client', None)
    if client is None:
        from alibabacloud_imagerecog20190930.client import Client
        from alibabacloud_tea_openapi.models import Config

        config = Config(
            access_key_id=settings.ALIYUN_ACCESS_KEY_ID,
            access_key_secret=settings.ALIYUN_ACCESS_KEY_SECRET,
            endpoint=settings.ALIYUN_IMAGERECOG_ENDPOINT,
            region_id=settings.ALIYUN_IMAGERECOG_REGION,
        )
        _thread_local.client = Client(config)
        client = _thread_local.client
    return client


def _compress_for_recognition(image_data: bytes) -> bytes:
    """Compress image to a small JPEG suitable for recognition API."""
    img = Image.open(io.BytesIO(image_data))
    img.thumbnail(RECOGNITION_MAX_SIZE, Image.LANCZOS)
    if img.mode not in ("RGB", "L"):
        img = img.convert("RGB")
    buf = io.BytesIO()
    img.save(buf, format="JPEG", quality=RECOGNITION_JPEG_QUALITY)
    return buf.getvalue()


def recognize_pet(image_data: bytes) -> ImageRecognitionResult:
    """Check whether image contains a pet using Aliyun RecognizeScene.

    Returns is_pet=True + skipped=True when the service is unavailable,
    so that the upload is not blocked.
    """
    if not _is_configured():
        logger.info("Image recognition not configured, skipping")
        return ImageRecognitionResult(is_pet=True, labels=[], skipped=True)

    try:
        from alibabacloud_imagerecog20190930.models import RecognizeSceneAdvanceRequest
        from alibabacloud_tea_util.models import RuntimeOptions

        client = _get_client()

        compressed = _compress_for_recognition(image_data)

        request = RecognizeSceneAdvanceRequest()
        request.image_urlobject = io.BytesIO(compressed)
        runtime = RuntimeOptions()
        runtime.connect_timeout = 5000   # 5s
        runtime.read_timeout = 8000      # 8s
        runtime.autoretry = False
        runtime.max_attempts = 1

        response = client.recognize_scene_advance(request, runtime)
        tags = response.body.data.tags or []

        labels: list[str] = []
        has_pet = False
        for tag in tags:
            label = f"{tag.value}({tag.confidence:.2f})"
            labels.append(label)
            if tag.confidence >= CONFIDENCE_THRESHOLD:
                tag_lower = tag.value.lower() if tag.value else ""
                if any(kw in tag_lower for kw in PET_KEYWORDS):
                    has_pet = True

        return ImageRecognitionResult(is_pet=has_pet, labels=labels, skipped=False)

    except Exception as e:
        logger.warning("Image recognition service error, allowing upload: %s", e)
        return ImageRecognitionResult(is_pet=True, labels=[], skipped=True)
