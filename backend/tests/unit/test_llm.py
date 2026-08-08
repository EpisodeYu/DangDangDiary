from __future__ import annotations

from datetime import date
from types import SimpleNamespace
from unittest.mock import AsyncMock

import pytest

from app.services import llm


@pytest.mark.asyncio
async def test_extract_intent_calls_scoped_gateway_in_json_mode(monkeypatch) -> None:
    create = AsyncMock(
        return_value=SimpleNamespace(
            choices=[
                SimpleNamespace(
                    message=SimpleNamespace(
                        content='{"intent":"routine","pet_name":"咪咪","confidence":90}'
                    )
                )
            ]
        )
    )
    client = SimpleNamespace(
        chat=SimpleNamespace(completions=SimpleNamespace(create=create))
    )
    monkeypatch.setattr(llm.settings, "LITELLM_API_KEY", "sk-diary-test")
    monkeypatch.setattr(llm.settings, "LITELLM_BASE_URL", "http://litellm:4000/v1")
    monkeypatch.setattr(llm.settings, "TONGYI_MODEL", "qwen-flash")
    monkeypatch.setattr(llm, "_get_client", lambda: client)

    result = await llm.extract_intent(
        "今天给咪咪洗澡",
        known_pet_names=["咪咪"],
        today=date(2026, 8, 8),
    )

    assert result["intent"] == "routine"
    assert result["_raw"].startswith('{"intent"')
    call = create.await_args.kwargs
    assert call["model"] == "qwen-flash"
    assert call["response_format"] == {"type": "json_object"}
    assert call["temperature"] == 0
    assert "当前日期：2026-08-08" in call["messages"][1]["content"]
    assert "候选宠物名" in call["messages"][1]["content"]


@pytest.mark.asyncio
async def test_extract_intent_requires_gateway_configuration(monkeypatch) -> None:
    monkeypatch.setattr(llm.settings, "LITELLM_API_KEY", "")
    with pytest.raises(llm.LlmUnavailableError, match="LITELLM_API_KEY"):
        await llm.extract_intent("今天洗澡")

    monkeypatch.setattr(llm.settings, "LITELLM_API_KEY", "sk-diary-test")
    monkeypatch.setattr(llm.settings, "LITELLM_BASE_URL", "")
    with pytest.raises(llm.LlmUnavailableError, match="LITELLM_BASE_URL"):
        await llm.extract_intent("今天洗澡")


@pytest.mark.asyncio
async def test_malformed_gateway_response_is_not_logged_verbatim(
    monkeypatch,
    caplog,
) -> None:
    secret_response = "not-json-private-response"
    create = AsyncMock(
        return_value=SimpleNamespace(
            choices=[
                SimpleNamespace(
                    message=SimpleNamespace(content=secret_response)
                )
            ]
        )
    )
    client = SimpleNamespace(
        chat=SimpleNamespace(completions=SimpleNamespace(create=create))
    )
    monkeypatch.setattr(llm.settings, "LITELLM_API_KEY", "sk-diary-test")
    monkeypatch.setattr(llm.settings, "LITELLM_BASE_URL", "http://litellm:4000/v1")
    monkeypatch.setattr(llm, "_get_client", lambda: client)

    with pytest.raises(llm.LlmUnavailableError, match="malformed json"):
        await llm.extract_intent("private transcript")

    assert secret_response not in caplog.text
    assert "private transcript" not in caplog.text
