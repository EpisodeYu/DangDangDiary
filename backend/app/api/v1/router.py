from fastapi import APIRouter

from app.api.v1 import auth, classify, pets, photos, health, share, voice

api_v1_router = APIRouter()
api_v1_router.include_router(auth.router)
# Share routes share the `/pets` prefix; register BEFORE pets.router so that
# `/pets/redeem` (literal) is matched before `/pets/{pet_id}` (int).
api_v1_router.include_router(share.router)
api_v1_router.include_router(pets.router)
# Classify owns `POST /photos/classify`; register BEFORE photos.router so
# the literal `/classify` path matches before the `/photos/{photo_id}`
# catch-alls inside photos.router (e.g. `/photos/{photo_id}/url`).
api_v1_router.include_router(classify.router)
api_v1_router.include_router(photos.router)  # no prefix, paths are inline
api_v1_router.include_router(health.router)
api_v1_router.include_router(voice.router)
