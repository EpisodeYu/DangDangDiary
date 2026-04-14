from fastapi import APIRouter

router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/send-code")
async def send_code():
    """Send SMS verification code. (Step 2)"""
    return {"message": "Not implemented yet"}


@router.post("/login")
async def login():
    """Login with phone + code. (Step 2)"""
    return {"message": "Not implemented yet"}


@router.post("/refresh")
async def refresh():
    """Refresh access token. (Step 2)"""
    return {"message": "Not implemented yet"}


@router.post("/logout")
async def logout():
    """Logout current device. (Step 2)"""
    return {"message": "Not implemented yet"}
