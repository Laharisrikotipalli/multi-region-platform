import asyncio
import os
import socket
import time

import asyncpg
import redis.asyncio as aioredis
from contextlib import asynccontextmanager
from fastapi import FastAPI, Response
from fastapi.middleware.cors import CORSMiddleware
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from prometheus_fastapi_instrumentator import Instrumentator

# ── Environment ───────────────────────────────────────────────────────────────
DATABASE_URL  = os.environ["DATABASE_URL"]   # postgresql://user:pass@host/db
REDIS_URL     = os.environ["REDIS_URL"]      # redis://host:6379
REGION        = os.getenv("AWS_REGION", "unknown")
OTLP_ENDPOINT = os.getenv("OTLP_ENDPOINT", "http://tempo:4317")

# ── OpenTelemetry tracing ─────────────────────────────────────────────────────
provider = TracerProvider()
provider.add_span_processor(
    BatchSpanProcessor(OTLPSpanExporter(endpoint=OTLP_ENDPOINT, insecure=True))
)
trace.set_tracer_provider(provider)
tracer = trace.get_tracer(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.db    = await asyncpg.create_pool(DATABASE_URL, min_size=1, max_size=5)
    app.state.redis = aioredis.from_url(REDIS_URL, decode_responses=True)
    yield
    await app.state.db.close()
    await app.state.redis.aclose()


app = FastAPI(title="Multi-Region Platform", version="1.0.0", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"]
)
Instrumentator().instrument(app).expose(app)
FastAPIInstrumentor.instrument_app(app)


# ── Routes ────────────────────────────────────────────────────────────────────

@app.get("/")
async def root():
    return {
        "message": "Multi-region platform running",
        "region": REGION,
        "hostname": socket.gethostname(),
    }


@app.get("/health")
async def health(response: Response):
    """
    Deep health check – verifies the web service, database connectivity,
    and Redis connectivity.

    Returns {"status": "ok"} with HTTP 200 when all checks pass.
    Returns {"status": "degraded"} with HTTP 503 if any dependency fails,
    causing Route 53 to remove this region from DNS rotation.
    """
    with tracer.start_as_current_span("health_check"):
        result = {
            "status": "ok",
            "region": REGION,
            "timestamp": time.time(),
            "checks": {},
        }
        errors = []

        # ── Database connectivity ─────────────────────────────────────────
        try:
            async with app.state.db.acquire() as conn:
                await asyncio.wait_for(conn.execute("SELECT 1"), timeout=3.0)
            result["checks"]["database"] = "ok"
        except Exception as exc:
            result["checks"]["database"] = f"error: {exc}"
            errors.append(f"database: {exc}")

        # ── Redis connectivity ────────────────────────────────────────────
        try:
            pong = await asyncio.wait_for(app.state.redis.ping(), timeout=3.0)
            result["checks"]["redis"] = "ok" if pong else "no-response"
            if not pong:
                errors.append("redis: no response to PING")
        except Exception as exc:
            result["checks"]["redis"] = f"error: {exc}"
            errors.append(f"redis: {exc}")

        if errors:
            result["status"] = "degraded"
            response.status_code = 503

        return result


@app.get("/info")
async def info():
    return {"region": REGION, "hostname": socket.gethostname(), "version": "1.0.0"}


@app.get("/data")
async def data():
    """Read from PostgreSQL, serve from Redis cache when available."""
    cache_key = f"data:{REGION}"
    cached = await app.state.redis.get(cache_key)
    if cached:
        return {"source": "cache", "region": REGION, "data": cached}

    async with app.state.db.acquire() as conn:
        rows = await conn.fetch("SELECT NOW() AS ts, current_database() AS db")
    payload = {"ts": str(rows[0]["ts"]), "db": rows[0]["db"]}
    await app.state.redis.setex(cache_key, 30, str(payload))
    return {"source": "database", "region": REGION, "data": payload}
