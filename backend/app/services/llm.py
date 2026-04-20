"""DashScope LLM (qwen-plus) intent extractor.

Talks to DashScope's OpenAI-compatible endpoint. Keeping the HTTP client
as `openai.AsyncOpenAI` lets us share auth plumbing with future
multimodal embedding work (phase 2 step 3) that also points at
`compatible-mode/v1`.
"""
from __future__ import annotations

import json
import logging
from typing import Any

from app.config import settings

logger = logging.getLogger(__name__)


class LlmUnavailableError(RuntimeError):
    """DashScope LLM 暂不可用（上游 5xx / 网络 / JSON 破损）。"""


# Prompt version — stored alongside each log so we can A/B prompts
# without mixing datasets. Bump on every semantic change.
PROMPT_VERSION = "voice-intake/v1"


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
    "1. 日期一律返回受限格式（today / yesterday / N_days_ago:<n> / YYYY-MM-DD），不要自己换算，由服务端解析。\n"
    "2. 只要一个字段你没有明确听到，就返回 null；禁止猜测。\n"
    "3. 如果这句话不是在记一件宠物相关的事，intent 直接返回 \"unknown\"，其余字段 null。\n"
    "4. routine_type 只接受 bath / nail_trim / grooming（洗澡 / 剪指甲 / 美容梳毛）。其它动作（散步、喂饭等）当作 unknown。\n"
    "5. pet_name 必须是「候选宠物名」列表里的精确字符串；即使用户说的名字发音相近、或是昵称的变体（如「咪咪」↔「米米」），也必须映射到列表中最可能对应的那个；如果列表为空、用户没提到宠物、或没有任何候选足够接近，返回 null。\n"
    "6. 只输出 JSON，不要解释。"
)


def _build_user_message(
    transcript: str,
    *,
    known_pet_names: list[str] | None,
    default_pet_name: str | None,
) -> str:
    """Compose the user-visible prompt.

    We pass the user's own pet list as a closed set so the LLM can
    correct for STT homophones (e.g. "咪咪" misheard as "米米"). The
    default pet name is a weaker hint — included so the model can
    prefer it when the audio genuinely doesn't mention any name.
    """
    lines: list[str] = []
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
) -> dict[str, Any]:
    """Call qwen-plus in JSON mode and return the parsed dict.

    Raises `LlmUnavailableError` on network, non-200, or malformed JSON.
    The caller persists both the raw string (in voice_intake_logs.llm_raw)
    and the parsed dict to make prompt iteration auditable.

    ``known_pet_names`` is the user's full pet list; passing it to the
    LLM lets it do homophone-tolerant matching against a closed set,
    which is much more robust than doing fuzzy matching *after* STT on
    the backend (STT accuracy on pet nicknames is the biggest source
    of missing `pet_id` in the wild).
    """
    if not settings.DASHSCOPE_API_KEY:
        raise LlmUnavailableError("DASHSCOPE_API_KEY is not configured")

    # Import lazily so unit tests can patch without requiring the dep
    # installed on every runner.
    from openai import AsyncOpenAI, OpenAIError

    client = AsyncOpenAI(
        api_key=settings.DASHSCOPE_API_KEY,
        base_url=settings.DASHSCOPE_BASE_URL,
    )

    user_msg = _build_user_message(
        transcript,
        known_pet_names=known_pet_names,
        default_pet_name=default_pet_name,
    )

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
    except OpenAIError as e:
        logger.warning("dashscope llm error: %s", e)
        raise LlmUnavailableError(str(e)) from e
    except Exception as e:  # network / SSL / other
        logger.warning("dashscope llm unexpected error: %s", e)
        raise LlmUnavailableError(str(e)) from e

    raw = resp.choices[0].message.content or "{}"
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as e:
        logger.warning("llm returned non-json: %r", raw[:500])
        raise LlmUnavailableError("malformed json") from e

    if not isinstance(parsed, dict):
        raise LlmUnavailableError("json is not an object")
    # Stash raw string so the caller can persist it without re-serialising.
    parsed["_raw"] = raw
    return parsed
