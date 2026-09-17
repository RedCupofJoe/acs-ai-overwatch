"""OpenAI-compatible chat completions client (llama.cpp, vLLM, or MaaS)."""

from __future__ import annotations

import json
import os
from collections.abc import Awaitable, Callable
from typing import Any

import httpx

ToolHandler = Callable[[dict[str, Any]], Awaitable[str] | str]


def _llm_request_kwargs() -> dict[str, Any]:
    return {
        "model": os.getenv("LLM_MODEL", "minicpm-abliterated"),
        "timeout": float(os.getenv("LLM_TIMEOUT_SEC", "180")),
        "temperature": float(os.getenv("LLM_TEMPERATURE", "0.7")),
        "max_tokens": int(os.getenv("LLM_MAX_TOKENS", "768")),
    }


def _llm_http_client(**kwargs: Any) -> httpx.AsyncClient:
    trust_env = os.getenv("LLM_TRUST_PROXY", "").strip().lower() in {"1", "true", "yes"}
    verify = os.getenv("LLM_TLS_VERIFY", "true").strip().lower() not in {"0", "false", "no"}
    headers = {}
    api_key = os.getenv("LLM_API_KEY", "").strip()
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"
    return httpx.AsyncClient(
        timeout=kwargs.pop("timeout", 180.0),
        trust_env=trust_env,
        verify=verify,
        headers=headers or None,
        **kwargs,
    )


async def chat_completion(system_prompt: str, user_text: str) -> str:
    base = os.getenv("LLM_API_BASE", "").strip().rstrip("/")
    if not base:
        raise RuntimeError("LLM_API_BASE is not configured")

    kwargs = _llm_request_kwargs()
    payload = {
        "model": kwargs["model"],
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_text or "Hello"},
        ],
        "temperature": kwargs["temperature"],
        "max_tokens": kwargs["max_tokens"],
    }

    async with _llm_http_client(timeout=kwargs["timeout"]) as client:
        response = await client.post(f"{base}/chat/completions", json=payload)
        response.raise_for_status()
        data = response.json()

    return _extract_message_content(data)


async def chat_completion_with_tools(
    system_prompt: str,
    user_text: str,
    tools: list[dict[str, Any]],
    tool_handlers: dict[str, ToolHandler],
    *,
    max_tool_rounds: int = 5,
) -> tuple[str, list[str]]:
    """Run an OpenAI-style tool loop; returns final assistant text and tool summaries."""
    base = os.getenv("LLM_API_BASE", "").strip().rstrip("/")
    if not base:
        raise RuntimeError("LLM_API_BASE is not configured")

    kwargs = _llm_request_kwargs()
    messages: list[dict[str, Any]] = [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": user_text or "Hello"},
    ]
    tool_summaries: list[str] = []

    async with _llm_http_client(timeout=kwargs["timeout"]) as client:
        for _ in range(max_tool_rounds):
            payload: dict[str, Any] = {
                "model": kwargs["model"],
                "messages": messages,
                "temperature": kwargs["temperature"],
                "max_tokens": kwargs["max_tokens"],
                "tools": tools,
            }
            response = await client.post(f"{base}/chat/completions", json=payload)
            if response.status_code == 400 and tools:
                plain_payload = {
                    "model": kwargs["model"],
                    "messages": messages,
                    "temperature": kwargs["temperature"],
                    "max_tokens": kwargs["max_tokens"],
                }
                response = await client.post(f"{base}/chat/completions", json=plain_payload)
            response.raise_for_status()
            data = response.json()

            choices = data.get("choices") or []
            if not choices:
                raise RuntimeError("LLM returned no choices")
            message = choices[0].get("message") or {}
            tool_calls = message.get("tool_calls") or []
            if not tool_calls:
                content = message.get("content")
                if not content:
                    raise RuntimeError("LLM returned empty content")
                return str(content).strip(), tool_summaries

            messages.append(message)
            for tool_call in tool_calls:
                function = tool_call.get("function") or {}
                name = function.get("name", "")
                raw_args = function.get("arguments") or "{}"
                try:
                    args = json.loads(raw_args)
                except json.JSONDecodeError:
                    args = {}
                handler = tool_handlers.get(name)
                if handler is None:
                    result = f"Unknown tool: {name}"
                else:
                    maybe = handler(args)
                    result = await maybe if hasattr(maybe, "__await__") else maybe
                tool_summaries.append(str(result))
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tool_call.get("id"),
                        "content": str(result),
                    }
                )

    raise RuntimeError("LLM exceeded maximum tool-call rounds")


def _extract_message_content(data: dict[str, Any]) -> str:
    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("LLM returned no choices")
    message = choices[0].get("message") or {}
    content = message.get("content")
    if not content:
        raise RuntimeError("LLM returned empty content")
    return str(content).strip()
