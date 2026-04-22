import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.config import settings
from app.exceptions import AppException
from app.api.v1.router import api_v1_router


# Surface application-level INFO logs (e.g. `app.api.v1.classify` slow-log
# `classify done total_ms=…`, `app.services.embedding` region elapsed) to
# uvicorn's stdout. Without this, uvicorn only configures its own
# `uvicorn` / `uvicorn.access` loggers and every `logger.info(...)` we
# write in the application tree disappears.
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)


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
