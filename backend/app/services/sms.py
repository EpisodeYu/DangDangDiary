import asyncio
import json
import logging

from alibabacloud_dypnsapi20170525.client import Client as DypnsClient
from alibabacloud_dypnsapi20170525 import models as dypns_models
from alibabacloud_tea_openapi import models as open_api_models

from app.config import settings
from app.exceptions import AppException

logger = logging.getLogger(__name__)

_client: DypnsClient | None = None


def _get_client() -> DypnsClient:
    global _client
    if _client is None:
        if not settings.ALIYUN_ACCESS_KEY_ID or not settings.ALIYUN_ACCESS_KEY_SECRET:
            raise AppException(
                502, "SMS_SEND_FAILED",
                "阿里云 AccessKey 未配置，请检查 .env 文件中的 ALIYUN_ACCESS_KEY_ID / ALIYUN_ACCESS_KEY_SECRET",
            )
        config = open_api_models.Config(
            access_key_id=settings.ALIYUN_ACCESS_KEY_ID,
            access_key_secret=settings.ALIYUN_ACCESS_KEY_SECRET,
        )
        config.endpoint = "dypnsapi.aliyuncs.com"
        _client = DypnsClient(config)
    return _client


def _do_send(phone: str):
    """Synchronous SDK call — executed in a thread via asyncio.to_thread."""
    client = _get_client()

    request = dypns_models.SendSmsVerifyCodeRequest(
        phone_number=phone,
        sign_name=settings.ALIYUN_SMS_SIGN_NAME,
        template_code=settings.ALIYUN_SMS_TEMPLATE_CODE,
        template_param=json.dumps({"code": "##code##", "min": "5"}),
        code_type=1,
        code_length=6,
        valid_time=300,
        interval=60,
        duplicate_policy=1,
        return_verify_code=True,
    )

    response = client.send_sms_verify_code(request)
    return response


async def send_verify_code(phone: str) -> str:
    """Send SMS and return the verification code string."""
    try:
        response = await asyncio.to_thread(_do_send, phone)
    except AppException:
        raise
    except Exception as e:
        logger.error("Aliyun SMS SDK error: %s", e)
        raise AppException(502, "SMS_SEND_FAILED", f"短信服务异常: {e}")

    body = response.body
    if not body or body.code != "OK" or not body.success:
        msg = getattr(body, "message", "未知错误") if body else "空响应"
        logger.error("Aliyun SMS API error: code=%s, message=%s",
                     getattr(body, "code", None), msg)
        raise AppException(502, "SMS_SEND_FAILED", f"短信发送失败: {msg}")

    verify_code = body.model.verify_code if body.model else None
    if not verify_code:
        raise AppException(502, "SMS_SEND_FAILED", "阿里云未返回验证码")

    return verify_code
