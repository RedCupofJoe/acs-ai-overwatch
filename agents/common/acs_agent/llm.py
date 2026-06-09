"""OpenAI-compatible chat completions client for shared vLLM backends."""

from __future__ import annotations

import os

import httpx


async def chat_completion(system_prompt: str, user_text: str) -> str:
    base = os.getenv("LLM_API_BASE", "").strip().rstrip("/")
    if not base:
        raise RuntimeError("LLM_API_BASE is not configured")

    model = os.getenv("LLM_MODEL", "HuggingFaceTB/SmolLM2-1.7B-Instruct")
    timeout = float(os.getenv("LLM_TIMEOUT_SEC", "120"))
    temperature = float(os.getenv("LLM_TEMPERATURE", "0.7"))
    max_tokens = int(os.getenv("LLM_MAX_TOKENS", "512"))

    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_text or "Hello"},
        ],
        "temperature": temperature,
        "max_tokens": max_tokens,
    }

    async with httpx.AsyncClient(timeout=timeout) as client:
        response = await client.post(f"{base}/chat/completions", json=payload)
        response.raise_for_status()
        data = response.json()

    choices = data.get("choices") or []
    if not choices:
        raise RuntimeError("LLM returned no choices")
    message = choices[0].get("message") or {}
    content = message.get("content")
    if not content:
        raise RuntimeError("LLM returned empty content")
    return str(content).strip()
