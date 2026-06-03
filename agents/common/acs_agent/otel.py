"""OpenTelemetry bootstrap for ACS agent images.

Exports traces when standard OTEL_* environment variables are set (Phase 5 GitOps).
No-ops cleanly when OTEL_EXPORTER_OTLP_ENDPOINT is unset so baseline deploys are unaffected.
"""

from __future__ import annotations

import os


def configure_otel() -> None:
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip()
    if not endpoint:
        return

    from opentelemetry import trace
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    service_name = os.getenv("OTEL_SERVICE_NAME", "acs-agent")
    resource = Resource.create(
        {
            "service.name": service_name,
            "deployment.environment": os.getenv(
                "OTEL_DEPLOYMENT_ENVIRONMENT", "acs-ai-overwatch"
            ),
        }
    )

    protocol = os.getenv("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc").lower()
    if protocol == "grpc":
        from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
            OTLPSpanExporter,
        )

        exporter = OTLPSpanExporter(endpoint=endpoint, insecure=True)
    else:
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
            OTLPSpanExporter,
        )

        traces_endpoint = endpoint
        if not traces_endpoint.startswith("http"):
            traces_endpoint = f"http://{endpoint}"
        if not traces_endpoint.rstrip("/").endswith("/v1/traces"):
            traces_endpoint = f"{traces_endpoint.rstrip('/')}/v1/traces"
        exporter = OTLPSpanExporter(endpoint=traces_endpoint)

    provider = TracerProvider(resource=resource)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)

    # kagenti-adk uses FastAPI/Starlette — instrument after provider is registered.
    try:
        from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
        from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor

        FastAPIInstrumentor().instrument()
        HTTPXClientInstrumentor().instrument()
    except Exception:
        # PoC: do not block agent startup if auto-instrumentation fails.
        pass
