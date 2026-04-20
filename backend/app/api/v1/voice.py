"""Voice intake routes (Phase 2 Step 2)."""
from fastapi import APIRouter, Depends, File, Form, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.responses import Response

from app.database import get_db
from app.dependencies import get_current_user_id
from app.schemas.voice_intake import (
    VoiceIntakeConfirmRequest,
    VoiceIntakeConfirmResponse,
    VoiceIntakeResponse,
)
from app.services import voice_intake as voice_intake_service


router = APIRouter(prefix="/voice", tags=["voice"])


@router.post("/intake", response_model=VoiceIntakeResponse)
async def intake(
    audio_file: UploadFile = File(...),
    client_request_id: str = Form(...),
    default_pet_id: int | None = Form(None),
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
) -> VoiceIntakeResponse:
    return await voice_intake_service.intake(
        db,
        user_id=user_id,
        audio=audio_file,
        default_pet_id=default_pet_id,
        client_request_id=client_request_id,
    )


@router.post("/intake/confirm", response_model=VoiceIntakeConfirmResponse)
async def confirm(
    body: VoiceIntakeConfirmRequest,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
) -> VoiceIntakeConfirmResponse:
    return await voice_intake_service.confirm(
        db,
        user_id=user_id,
        request_id=body.request_id,
        intent=body.intent,
        payload=body.payload,
    )


@router.delete("/intake/{request_id}", status_code=204)
async def cancel(
    request_id: str,
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
) -> Response:
    await voice_intake_service.cancel(
        db, user_id=user_id, request_id=request_id,
    )
    return Response(status_code=204)
