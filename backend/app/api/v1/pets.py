from fastapi import APIRouter

router = APIRouter(prefix="/pets", tags=["pets"])


@router.post("")
async def create_pet():
    """Create a pet profile. (Step 3)"""
    return {"message": "Not implemented yet"}


@router.get("")
async def list_pets():
    """List all pets for the current user. (Step 3)"""
    return {"pets": []}


@router.put("/{pet_id}")
async def update_pet(pet_id: int):
    """Update a pet profile. (Step 3)"""
    return {"message": "Not implemented yet"}


@router.delete("/{pet_id}", status_code=204)
async def delete_pet(pet_id: int):
    """Delete a pet profile. (Step 3)"""
    return None
