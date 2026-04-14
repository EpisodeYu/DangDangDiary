from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.post("/pets/{pet_id}/weights")
async def create_weight(pet_id: int):
    """Record pet weight. (Step 5)"""
    return {"message": "Not implemented yet"}


@router.get("/pets/{pet_id}/weights")
async def list_weights(pet_id: int):
    """Get weight history. (Step 5)"""
    return {"weights": []}


@router.post("/pets/{pet_id}/dewormings")
async def create_deworming(pet_id: int):
    """Record deworming. (Step 5)"""
    return {"message": "Not implemented yet"}


@router.get("/pets/{pet_id}/dewormings")
async def list_dewormings(pet_id: int):
    """Get deworming history. (Step 5)"""
    return {"dewormings": []}


@router.post("/pets/{pet_id}/vaccinations")
async def create_vaccination(pet_id: int):
    """Record vaccination. (Step 5)"""
    return {"message": "Not implemented yet"}


@router.get("/pets/{pet_id}/vaccinations")
async def list_vaccinations(pet_id: int):
    """Get vaccination history. (Step 5)"""
    return {"vaccinations": []}
