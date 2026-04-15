from fastapi import APIRouter, Depends, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.auth import (
    LoginRequest,
    LogoutRequest,
    RefreshRequest,
    RefreshResponse,
    SendCodeRequest,
    SendCodeResponse,
    TokenResponse,
    UpdateUserRequest,
    UserResponse,
)
from app.services import auth as auth_service

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/send-code", response_model=SendCodeResponse)
async def send_code(body: SendCodeRequest):
    await auth_service.send_code(body.phone)
    return SendCodeResponse()


@router.post("/login", response_model=TokenResponse)
async def login(body: LoginRequest, db: AsyncSession = Depends(get_db)):
    access_token, refresh_token, user = await auth_service.login(
        body.phone, body.code, db
    )
    return TokenResponse(
        access_token=access_token,
        refresh_token=refresh_token,
        user=UserResponse.model_validate(user),
    )


@router.post("/refresh", response_model=RefreshResponse)
async def refresh(body: RefreshRequest, db: AsyncSession = Depends(get_db)):
    access_token = await auth_service.refresh_access_token(body.refresh_token, db)
    return RefreshResponse(access_token=access_token)


@router.post("/logout", status_code=204)
async def logout(
    body: LogoutRequest,
    current_user: User = Depends(get_current_user),
):
    await auth_service.logout(current_user.id, body.refresh_token)
    return Response(status_code=204)


@router.get("/me", response_model=UserResponse)
async def get_me(current_user: User = Depends(get_current_user)):
    return UserResponse.model_validate(current_user)


@router.put("/me", response_model=UserResponse)
async def update_me(
    body: UpdateUserRequest,
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    current_user.nickname = body.nickname
    await db.flush()
    return UserResponse.model_validate(current_user)
