import io
import logging
from typing import TypedDict

from app.config import settings

logger = logging.getLogger(__name__)

PET_KEYWORDS = {
    "cat", "kitten", "kitty", "feline",
    "dog", "puppy", "canine", "hound",
    "猫", "小猫", "猫咪", "犬", "狗", "小狗", "宠物", "pet",
}

CONFIDENCE_THRESHOLD = 0.3


class ImageRecognitionResult(TypedDict):
    is_pet: bool
    labels: list[str]
    skipped: bool


def _is_configured() -> bool:
    return bool(settings.ALIYUN_ACCESS_KEY_ID and settings.ALIYUN_ACCESS_KEY_SECRET)


def recognize_pet(image_data: bytes) -> ImageRecognitionResult:
    """Check whether image contains a pet using Aliyun RecognizeScene.

    Returns is_pet=True + skipped=True when the service is unavailable,
    so that the upload is not blocked.
    """
    if not _is_configured():
        logger.info("Image recognition not configured, skipping")
        return ImageRecognitionResult(is_pet=True, labels=[], skipped=True)

    try:
        from alibabacloud_imagerecog20190930.client import Client
        from alibabacloud_imagerecog20190930.models import RecognizeSceneAdvanceRequest
        from alibabacloud_tea_openapi.models import Config
        from alibabacloud_tea_util.models import RuntimeOptions

        config = Config(
            access_key_id=settings.ALIYUN_ACCESS_KEY_ID,
            access_key_secret=settings.ALIYUN_ACCESS_KEY_SECRET,
            endpoint=settings.ALIYUN_IMAGERECOG_ENDPOINT,
            region_id=settings.ALIYUN_IMAGERECOG_REGION,
        )
        client = Client(config)

        request = RecognizeSceneAdvanceRequest()
        request.image_urlobject = io.BytesIO(image_data)
        runtime = RuntimeOptions()

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
