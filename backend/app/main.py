from fastapi import APIRouter, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text

from app.config import settings
from app.db import SessionDep
from app.routers import meetings, participants

app = FastAPI(
    title="Meetings API",
    docs_url="/api/docs",
    redoc_url=None,
    openapi_url="/api/openapi.json",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins,
    allow_methods=["*"],
    allow_headers=["*"],
)

api = APIRouter(prefix="/api")


@api.get("/health", tags=["health"])
async def health(session: SessionDep) -> dict[str, str]:
    await session.execute(text("SELECT 1"))
    return {"status": "ok"}


api.include_router(meetings.router)
api.include_router(participants.router)
app.include_router(api)
