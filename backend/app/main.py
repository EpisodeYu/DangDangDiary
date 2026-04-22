import logging
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.config import settings
from app.exceptions import AppException
from app.api.v1.router import api_v1_router


# [DEBUG-2026-04-22] classify timeout investigation.
# Surface application-level INFO logs (so `logger.info(...)` in
# app.services.embedding and app.api.v1.classify actually prints) and
# tag every /photos/classify request with a per-request timer. Keep this
# until the root cause is confirmed, then consider trimming verbosity.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
_debug_log = logging.getLogger("app.debug.classify")


@asynccontextmanager
async def lifespan(app: FastAPI):
    from app.services.redis import init_redis, close_redis
    from app.services.storage import aensure_all_buckets
    from app.utils.production_check import assert_production_safe

    assert_production_safe(settings)
    await init_redis()
    # Pre-create MinIO buckets once at startup so request-time paths can
    # skip `_ensure_bucket` entirely. (Step 8 §1.2 storage P1 / Chunk B-5)
    await aensure_all_buckets()
    yield
    await close_redis()


app = FastAPI(
    title=settings.APP_NAME,
    version="1.0.0",
    lifespan=lifespan,
)


@app.middleware("http")
async def _classify_timing_middleware(request: Request, call_next):
    """[DEBUG-2026-04-22] log wall-clock time spent inside FastAPI for the
    classify endpoint only. Combined with nginx's `$request_time`, this
    tells us whether a slow classify is (a) the app doing work, (b) nginx
    buffering the body, or (c) the phone-to-nginx hop."""
    if "/photos/classify" not in request.url.path:
        return await call_next(request)
    rid = uuid.uuid4().hex[:8]
    client = request.client.host if request.client else "?"
    cl = request.headers.get("content-length", "?")
    _debug_log.info(
        "classify[%s] ENTER client=%s content_length=%s ua=%s",
        rid, client, cl, request.headers.get("user-agent", "?")[:60],
    )
    t0 = time.perf_counter()
    try:
        response = await call_next(request)
    except Exception as e:
        dt = time.perf_counter() - t0
        _debug_log.exception(
            "classify[%s] EXIT-EXC after %.2fs err=%s", rid, dt, e,
        )
        raise
    dt = time.perf_counter() - t0
    _debug_log.info(
        "classify[%s] EXIT status=%s elapsed=%.2fs",
        rid, response.status_code, dt,
    )
    return response


@app.exception_handler(AppException)
async def app_exception_handler(request: Request, exc: AppException):
    return JSONResponse(
        status_code=exc.status_code,
        content={"code": exc.code, "message": exc.message, "details": exc.details},
    )


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    errors = exc.errors()
    for error in errors:
        loc = error.get("loc", ())
        field_names = {str(part) for part in loc}
        if "phone" in field_names:
            return JSONResponse(
                status_code=400,
                content={"code": "INVALID_PHONE", "message": "手机号格式不正确", "details": None},
            )
        if "code" in field_names:
            return JSONResponse(
                status_code=400,
                content={"code": "INVALID_VERIFY_CODE", "message": "验证码格式不正确", "details": None},
            )
        if "nickname" in field_names:
            return JSONResponse(
                status_code=400,
                content={"code": "INVALID_NICKNAME", "message": "昵称不合法", "details": None},
            )

    safe_errors = []
    for error in errors:
        loc = error.get("loc")
        safe_error = {
            "loc": [str(part) for part in loc] if loc else [],
            "msg": str(error.get("msg", "")),
            "type": str(error.get("type", "")),
        }
        safe_errors.append(safe_error)

    first_msg = safe_errors[0]["msg"] if safe_errors else "请求参数校验失败"
    return JSONResponse(
        status_code=400,
        content={
            "code": "VALIDATION_ERROR",
            "message": first_msg,
            "details": safe_errors,
        },
    )


app.include_router(api_v1_router, prefix="/api/v1")


@app.get("/health")
async def health_check():
    return {"status": "ok"}
