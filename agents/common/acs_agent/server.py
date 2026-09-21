"""FastAPI agent runtime for ACS AI Overwatch (rogue: UBI open harness; remediations: OpenShell)."""

from __future__ import annotations

import os
from contextlib import nullcontext
from pathlib import Path
from typing import Any

from fastapi import FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from acs_agent.career import (
    CAREER_HANDLERS,
    CAREER_TOOLS,
    career_dataset_info,
    looks_like_career_question,
    query_career_dataset,
)
from acs_agent.llm import chat_completion, chat_completion_with_tools
from acs_agent.otel import configure_otel
from acs_agent.tools import NETWORK_RECON_TOOLS, RECON_HANDLERS, run_network_recon

configure_otel()

app = FastAPI(title="ACS AI Overwatch Agent", version="0.5.0")
_tracer = None

try:
    from opentelemetry import trace

    _tracer = trace.get_tracer("acs_agent.server")
except Exception:
    pass


class ChatRequest(BaseModel):
    message: str = ""
    text: str = ""


class ChatResponse(BaseModel):
    reply: str
    role: str = Field(default_factory=lambda: os.getenv("AGENT_ROLE", "agent"))


class OpenAIMessage(BaseModel):
    role: str
    content: str | None = None


class OpenAIChatRequest(BaseModel):
    messages: list[OpenAIMessage] = Field(default_factory=list)
    model: str | None = None


def load_system_prompt() -> str:
    candidates = [
        os.getenv("AGENT_SYSTEM_PROMPT_FILE", ""),
        os.getenv("OPENSHELL_SYSTEM_PROMPT_FILE", ""),
        "/etc/openshell/agent/system_prompt.txt",
        "/etc/acs-agent/system_prompt.txt",
    ]
    for path in candidates:
        prompt_path = Path(path)
        if path and prompt_path.is_file():
            return prompt_path.read_text(encoding="utf-8").strip()
    return "You are an ACS AI Overwatch evaluation agent."


def _user_text_from_openai(messages: list[OpenAIMessage]) -> str:
    for message in reversed(messages):
        if message.role == "user" and message.content:
            return message.content.strip()
    return ""


async def handle_user_text(user_text: str) -> str:
    audit_command = os.getenv("NETWORK_AUDIT_COMMAND", "Network Audit")
    enable_audit = os.getenv("AGENT_ENABLE_NETWORK_AUDIT", "false").lower() == "true"
    auto_audit = os.getenv("AGENT_AUTO_NETWORK_AUDIT", "false").lower() == "true"
    llm_driven_audit = os.getenv("AGENT_LLM_DRIVEN_NETWORK_AUDIT", "false").lower() == "true"
    explicit_audit = bool(enable_audit and user_text and user_text.lower() == audit_command.lower())
    should_audit = enable_audit and not llm_driven_audit and (auto_audit or explicit_audit)

    span_cm = (
        _tracer.start_as_current_span("acs_agent.handle_message")
        if _tracer
        else nullcontext()
    )
    with span_cm as span:
        if span is not None:
            span.set_attribute("agent.user_message.length", len(user_text))
            span.set_attribute("agent.network_audit_enabled", enable_audit)
            span.set_attribute("agent.role", os.getenv("AGENT_ROLE", "agent"))

        audit_summary = ""
        if enable_audit and llm_driven_audit and explicit_audit:
            return run_network_recon({"reason": audit_command})

        if should_audit:
            trigger = audit_command if explicit_audit else "automatic recon (every message)"
            if span is not None:
                span.add_event("network_audit.triggered", {"trigger": trigger})
            audit_summary = run_network_recon({"reason": trigger})
            if explicit_audit and not auto_audit:
                return audit_summary

        system_prompt = load_system_prompt()
        llm_api_base = os.getenv("LLM_API_BASE", "").strip()
        enable_career = os.getenv("AGENT_ENABLE_CAREER_CSV", "false").lower() == "true"
        if llm_api_base:
            try:
                if enable_audit and llm_driven_audit:
                    llm_reply, tool_summaries = await chat_completion_with_tools(
                        system_prompt,
                        user_text,
                        tools=NETWORK_RECON_TOOLS,
                        tool_handlers=RECON_HANDLERS,
                    )
                    if audit_summary and audit_summary not in tool_summaries:
                        tool_summaries.insert(0, audit_summary)
                    if tool_summaries:
                        llm_reply = "\n\n".join([*tool_summaries, llm_reply])
                elif enable_career:
                    llm_reply = await _career_chat(system_prompt, user_text)
                    if audit_summary:
                        llm_reply = f"{audit_summary}\n\n{llm_reply}"
                else:
                    llm_reply = await chat_completion(system_prompt, user_text)
                    if audit_summary:
                        llm_reply = f"{audit_summary}\n\n{llm_reply}"
                return llm_reply
            except Exception as exc:
                return f"LLM request failed: {exc}"

        persona_line = system_prompt.splitlines()[0] if system_prompt else "ACS agent"
        if enable_career:
            info = career_dataset_info()
            sample = query_career_dataset({"operation": "sample", "limit": 5})
            return f"{persona_line}\n\n{info}\n\n{sample}"
        parts = [persona_line, "", f"Received: {user_text or '(empty message)'}"]
        if audit_summary:
            parts.extend(["", audit_summary])
        return "\n".join(parts)


async def _career_chat(system_prompt: str, user_text: str) -> str:
    reply, summaries = await chat_completion_with_tools(
        system_prompt,
        user_text,
        tools=CAREER_TOOLS,
        tool_handlers=CAREER_HANDLERS,
    )
    if summaries or not looks_like_career_question(user_text):
        return reply
    fallback = query_career_dataset({"operation": "sample", "limit": 8})
    info = career_dataset_info()
    follow_up = (
        "The model skipped the CSV tool. Use this tool output to answer the user. "
        "Do not invent numbers.\n\n"
        f"DATASET INFO:\n{info}\n\nSAMPLE:\n{fallback}"
    )
    return await chat_completion(system_prompt, f"{user_text}\n\n{follow_up}")


_UI_DIR = Path(os.getenv("AGENT_UI_DIR", "/opt/acs-agent-ui"))
if (_UI_DIR / "index.html").is_file():
    app.mount("/static", StaticFiles(directory=str(_UI_DIR)), name="ui-static")

    @app.get("/")
    def ui_index() -> FileResponse:
        return FileResponse(_UI_DIR / "index.html")


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok", "role": os.getenv("AGENT_ROLE", "agent")}


@app.post("/chat", response_model=ChatResponse)
async def chat(request: ChatRequest) -> ChatResponse:
    text = (request.message or request.text or "").strip()
    reply = await handle_user_text(text)
    return ChatResponse(reply=reply)


@app.post("/v1/chat/completions")
async def openai_chat(request: OpenAIChatRequest) -> dict[str, Any]:
    user_text = _user_text_from_openai(request.messages)
    reply = await handle_user_text(user_text)
    model = request.model or os.getenv("LLM_MODEL", "acs-agent")
    return {
        "id": "acs-agent",
        "object": "chat.completion",
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": reply},
                "finish_reason": "stop",
            }
        ],
    }


def run() -> None:
    import uvicorn

    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    uvicorn.run(app, host=host, port=port)


if __name__ == "__main__":
    run()
