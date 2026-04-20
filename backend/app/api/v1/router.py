from fastapi import APIRouter

from app.api.v1 import auth, pets, photos, health, share, voice

api_v1_router = APIRouter()
api_v1_router.include_router(auth.router)
# Share routes share the `/pets` prefix; register BEFORE pets.router so that
# `/pets/redeem` (literal) is matched before `/pets/{pet_id}` (int).
api_v1_router.include_router(share.router)
api_v1_router.include_router(pets.router)
api_v1_router.include_router(photos.router)  # no prefix, paths are inline
api_v1_router.include_router(health.router)
api_v1_router.include_router(voice.router)
