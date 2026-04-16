from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.config import settings
from app.exceptions import AppException
from app.api.v1.router import api_v1_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    from app.services.redis import init_redis, close_redis

    await init_redis()
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
