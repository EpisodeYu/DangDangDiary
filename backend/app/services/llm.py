"""LiteLLM-backed ``qwen-flash`` intent extractor.

The Diary service holds only its scoped gateway key. The shared LiteLLM
gateway owns the Singapore/Beijing deployments, provider credentials,
retry, fallback, circuit breaking, and audit.
"""
from __future__ import annotations

import json
import logging
from datetime import date
from typing import Any

from app.config import settings

logger = logging.getLogger(__name__)


class LlmUnavailableError(RuntimeError):
    """LiteLLM gateway 暂不可用（上游 5xx / 网络 / JSON 破损）。"""


_client: Any | None = None


def _get_client():  # type: ignore[no-untyped-def]
    from openai import AsyncOpenAI

    global _client
    if _client is None:
        _client = AsyncOpenAI(
            api_key=settings.LITELLM_API_KEY,
            base_url=settings.LITELLM_BASE_URL,
        )
    return _client


# Prompt version — stored alongside each log so we can A/B prompts
# without mixing datasets. Bump on every semantic change.
# v2 (2026-04-21): inject current date into the user message so the LLM
# can resolve "上个月 8 号 / 前天 / 上周三" against a real calendar.
# Before v2, the LLM had no date anchor and would hallucinate ISO dates
# from training-data priors (e.g. "上个月 8 号" → 2024-05-08).
PROMPT_VERSION = "voice-intake/v2"


SYSTEM_PROMPT = (
    "你是一个宠物日记的信息抽取助手。用户会说一句中文，你必须输出 JSON，字段如下：\n"
    "{\n"
    "  \"intent\": \"deworming\" | \"vaccination\" | \"weight\" | \"routine\" | \"unknown\",\n"
    "  \"pet_name\": string | null,            // 必须来自「候选宠物名」列表，若无候选或听不准则 null\n"
    "  \"dewormed_at\": \"YYYY-MM-DD\" | \"today\" | \"yesterday\" | \"N_days_ago:<n>\" | null,\n"
    "  \"deworming_type\": \"internal\" | \"external\" | \"combined\" | null,\n"
    "  \"vaccine_name\": string | null,\n"
    "  \"vaccinated_at\": \"YYYY-MM-DD\" | \"today\" | \"yesterday\" | \"N_days_ago:<n>\" | null,\n"
    "  \"weight_kg\": number | null,\n"
    "  \"weighed_at\": \"YYYY-MM-DD\" | \"today\" | \"yesterday\" | \"N_days_ago:<n>\" | null,\n"
    "  \"routine_type\": \"bath\" | \"nail_trim\" | \"grooming\" | null,\n"
    "  \"routine_at\": \"YYYY-MM-DD\" | \"today\" | \"yesterday\" | \"N_days_ago:<n>\" | null,\n"
    "  \"note\": string | null,\n"
    "  \"confidence\": integer 0-100\n"
    "}\n"
    "规则：\n"
    "1. 日期字段输出规范：\n"
    "   - 用户说「今天」→ \"today\"；说「昨天」→ \"yesterday\"；说「前天 / N 天前」→ \"N_days_ago:<n>\"（n 为整数天数）。\n"
    "   - 其它相对表达（如「上个月 8 号」「上周三」「大前天」「两周前」「去年 5 月」等）必须**基于 user 消息里给出的「当前日期」** 换算为 \"YYYY-MM-DD\"；禁止在没有「当前日期」的情况下凭空写日期。\n"
    "   - 用户直接说了绝对日期（如「3 月 8 号」）也基于「当前日期」补全年份后输出 \"YYYY-MM-DD\"，默认选择**不晚于当前日期**的最近一次；如果明确说了年份就照用。\n"
    "   - 输出的 YYYY-MM-DD 不得晚于「当前日期」。\n"
    "2. 只要一个字段你没有明确听到，就返回 null；禁止猜测。\n"
    "3. 如果这句话不是在记一件宠物相关的事，intent 直接返回 \"unknown\"，其余字段 null。\n"
    "4. routine_type 只接受 bath / nail_trim / grooming（洗澡 / 剪指甲 / 美容梳毛）。其它动作（散步、喂饭等）当作 unknown。\n"
    "5. pet_name 必须是「候选宠物名」列表里的精确字符串；即使用户说的名字发音相近、或是昵称的变体（如「咪咪」↔「米米」），也必须映射到列表中最可能对应的那个；如果列表为空、用户没提到宠物、或没有任何候选足够接近，返回 null。\n"
    "6. 只输出 JSON，不要解释。"
)


# Chinese weekday names, index 0 = Monday to match `date.weekday()`.
_WEEKDAY_ZH = ("星期一", "星期二", "星期三", "星期四", "星期五", "星期六", "星期日")


def _build_user_message(
    transcript: str,
    *,
    known_pet_names: list[str] | None,
    default_pet_name: str | None,
    today: date | None = None,
) -> str:
    """Compose the user-visible prompt.

    We pass the user's own pet list as a closed set so the LLM can
    correct for STT homophones (e.g. "咪咪" misheard as "米米"). The
    default pet name is a weaker hint — included so the model can
    prefer it when the audio genuinely doesn't mention any name.

    ``today`` anchors the LLM's date arithmetic. Without it, relative
    phrases like "上个月 8 号" make the model hallucinate ISO dates
    from training-data priors. Callers **should** pass an explicit
    China-calendar `today` (see `app.utils.time.today_cn`); the fallback
    here uses CN time too, so we never accidentally ship a UTC/JST day
    if a caller forgets.
    """
    if today is None:
        # Import locally to keep `llm.py` reusable outside the FastAPI
        # app (e.g. offline golden-set regression scripts) without a
        # circular / heavy import at module load.
        from app.utils.time import today_cn
        today = today_cn()
    lines: list[str] = [
        f"当前日期：{today.isoformat()}（{_WEEKDAY_ZH[today.weekday()]}）",
    ]
    if known_pet_names:
        # Quote names so punctuation in a pet name can't break parsing.
        quoted = "、".join(f"「{n}」" for n in known_pet_names)
        lines.append(f"候选宠物名（必须从中选一个或返回 null）：{quoted}")
    else:
        lines.append("候选宠物名：（该用户暂无宠物档案）")
    if default_pet_name:
        lines.append(f"当前记录页默认选中的宠物：「{default_pet_name}」")
    lines.append(f"用户语音转写：{transcript}")
    return "\n".join(lines)


async def extract_intent(
    transcript: str,
    *,
    known_pet_names: list[str] | None = None,
    default_pet_name: str | None = None,
    today: date | None = None,
) -> dict[str, Any]:
    """Call the configured LLM (default ``qwen-flash``) in JSON mode and
    return the parsed dict.

    Raises `LlmUnavailableError` on network, non-200, or malformed JSON.
    The caller persists both the raw string (in voice_intake_logs.llm_raw)
    and the parsed dict to make prompt iteration auditable.

    ``known_pet_names`` is the user's full pet list; passing it to the
    LLM lets it do homophone-tolerant matching against a closed set,
    which is much more robust than doing fuzzy matching *after* STT on
    the backend (STT accuracy on pet nicknames is the biggest source
    of missing `pet_id` in the wild).
    """
    if not settings.LITELLM_API_KEY:
        raise LlmUnavailableError("LITELLM_API_KEY is not configured")
    if not settings.LITELLM_BASE_URL:
        raise LlmUnavailableError("LITELLM_BASE_URL is not configured")

    # Import lazily so unit tests can patch without requiring the dep
    # installed on every runner.
    from openai import OpenAIError

    user_msg = _build_user_message(
        transcript,
        known_pet_names=known_pet_names,
        default_pet_name=default_pet_name,
        today=today,
    )

    client = _get_client()
    try:
        resp = await client.chat.completions.create(
            model=settings.TONGYI_MODEL,
            messages=[
                {"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": user_msg},
            ],
            response_format={"type": "json_object"},
            temperature=0,
            top_p=1,
            max_tokens=300,
            seed=42,
        )
    except OpenAIError as exc:
        logger.warning("gateway llm error: %s", type(exc).__name__)
        raise LlmUnavailableError(str(exc)) from exc
    except Exception as exc:
        logger.warning("gateway llm unexpected error: %s", type(exc).__name__)
        raise LlmUnavailableError(str(exc)) from exc

    raw = resp.choices[0].message.content or "{}"
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.warning("gateway llm returned non-json response length=%d", len(raw))
        raise LlmUnavailableError("malformed json") from exc

    if not isinstance(parsed, dict):
        raise LlmUnavailableError("json is not an object")

    logger.info("gateway llm model=%s ok", settings.TONGYI_MODEL)
    parsed["_raw"] = raw
    return parsed
