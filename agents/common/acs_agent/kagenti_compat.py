"""Kagenti platform compatibility shims for kagenti-adk + Kagenti backend."""

from __future__ import annotations

from typing import Any

from a2a.server.apps.jsonrpc import A2AFastAPIApplication
from fastapi import FastAPI


def patch_kagenti_adk_create_app() -> None:
    """Enable A2A v0.3 method names and root JSON-RPC routing for Kagenti backend."""
    import kagenti_adk.server.app as adk_app_module

    if getattr(adk_app_module.create_app, "_acs_patched", False):
        return

    original_create_app = adk_app_module.create_app
    original_a2a_init = A2AFastAPIApplication.__init__

    def a2a_init_with_v03_compat(self: A2AFastAPIApplication, *args: Any, **kwargs: Any) -> None:
        kwargs.setdefault("enable_v0_3_compat", True)
        original_a2a_init(self, *args, **kwargs)

    def patched_create_app(*args: Any, **kwargs: Any) -> FastAPI:
        A2AFastAPIApplication.__init__ = a2a_init_with_v03_compat  # type: ignore[method-assign]
        try:
            app = original_create_app(*args, **kwargs)
        finally:
            A2AFastAPIApplication.__init__ = original_a2a_init  # type: ignore[method-assign]

        @app.middleware("http")
        async def forward_root_jsonrpc(request, call_next):
            if request.method == "POST" and request.url.path in ("/", ""):
                request.scope["path"] = "/jsonrpc/"
                request.scope["raw_path"] = b"/jsonrpc/"
            return await call_next(request)

        return app

    patched_create_app._acs_patched = True  # type: ignore[attr-defined]
    adk_app_module.create_app = patched_create_app
