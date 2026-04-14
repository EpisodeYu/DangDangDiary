from fastapi import APIRouter

from app.api.v1 import auth, pets, photos, health

api_v1_router = APIRouter()
api_v1_router.include_router(auth.router)
api_v1_router.include_router(pets.router)
api_v1_router.include_router(photos.router)
api_v1_router.include_router(health.router)
