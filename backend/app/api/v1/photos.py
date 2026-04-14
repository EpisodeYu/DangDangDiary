from fastapi import APIRouter

router = APIRouter(prefix="/photos", tags=["photos"])


@router.get("/timeline")
async def get_timeline():
    """Get timeline photos with pagination. (Step 4/6)"""
    return {"photos": []}
