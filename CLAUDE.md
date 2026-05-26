# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**当当日记 (DangDang Diary)** — a pet diary mobile app. Phase 1 is an MVP; Phase 2 adds AI and social features.

- **Frontend**: Flutter 3.x (Dart), state management via Riverpod
- **Backend**: Python 3.11+ FastAPI
- **Infra**: PostgreSQL 16, Redis 7, MinIO (S3-compatible), Nginx reverse proxy, Docker Compose

The repo is currently in the planning/documentation phase. Implementation follows the step-by-step guides in `docs/`.

## Development Workflow

Each step doc (`docs/step1-*.md` through `docs/step8-*.md`) is the authoritative spec for that step. Always read the relevant step doc before implementing. General order:

1. Read step doc, propose a plan
2. Implement backend API first (test with FastAPI Swagger UI at `/docs`)
3. Implement Flutter frontend
4. Front-end/backend integration test on real device
5. Git commit

### Key Commands (once implemented)

The backend (FastAPI) runs **inside docker compose** (service `fastapi`), with the
source bind-mounted and `--reload` on — editing backend code hot-reloads, no rebuild.
See `docs/deploy-ops.md` for the full ops runbook.

```bash
# Start the whole stack (FastAPI + PG + Redis + MinIO + Nginx)
docker compose up -d

# Backend: run migrations (must run INSIDE the container — .env uses
# compose service names like `postgres`, unresolvable from the host)
docker compose exec fastapi alembic upgrade head

# Backend: restart after editing .env / rebuild after editing requirements.txt
docker compose restart fastapi
docker compose build fastapi && docker compose up -d fastapi

# Backend: logs
docker compose logs -f fastapi

# Frontend: run on device
cd frontend && flutter run

# Frontend: build release APK (inject the real domain at build time)
cd frontend && flutter build apk --release --dart-define=BASE_URL=https://dangdangdiary.org
```

## Architecture

```
Phone → Nginx (:80/:443)
          ├── /api/...   → FastAPI (:8000)
          └── /media/... → MinIO (:9000)
```

The phone client **only** talks to Nginx. Internal service addresses (`minio:9000`, `fastapi:8000`) must never be returned in API responses.

### Backend structure (`backend/app/`)
- `main.py` — FastAPI entry point, registers routers and exception handlers
- `config.py` — all config from `.env`
- `database.py` — SQLAlchemy session
- `models/` — SQLAlchemy ORM models
- `schemas/` — Pydantic request/response models
- `api/` — route handlers (`auth.py`, `pets.py`, `photos.py`, `health.py`)
- `services/` — business logic
- `utils/` — helpers

### Frontend structure (`frontend/lib/`)
- `main.dart` — entry, route setup, theme
- `config/` — constants, theme, base URL config
- `models/` — data models
- `services/` — API calls
- `providers/` — Riverpod providers
- `screens/` — pages: `auth/`, `record/`, `health/`, `timeline/`, `profile/`
- `widgets/` — reusable components

## API Conventions (must follow)

- Fields: `snake_case`
- Pagination: `page` + `page_size`; list response uses semantic keys (`pets`, `photos`, `weights`)
- List order: newest first
- Create/update → return the full updated object
- Delete → `204 No Content`
- Empty list → `200` + empty array
- Timestamps stored as UTC; date-only fields use `date` type

## Error Response Format

```json
{ "code": "...", "message": "...", "details": {...} }
```
- Invalid input → `400`
- Permission denied → `403`
- Register a FastAPI `RequestValidationError` handler to convert Pydantic errors to this format.

## Auth

- SMS via Aliyun Dypnsapi `SendSmsVerifyCode`; code stored in Redis (5 min TTL, 60 s resend cooldown)
- JWT: Access Token (2 h) + Refresh Token (30 d)
- `POST /api/v1/auth/logout` invalidates the current device's refresh token only
- First login auto-creates the user account

## Media

- Frontend converts HEIC/HEIF → JPEG before upload
- Backend accepts JPG / PNG / WEBP
- On upload, backend calls Aliyun `RecognizeScene` to verify the image contains a cat or dog; reject with a user-friendly message if not
- Store original + thumbnail in MinIO; return thumbnail URL in list responses, original URL on detail view
- EXIF date (`DateTimeOriginal`) is extracted on the Flutter side using the `exif` package

## Configuration & Secrets

- Backend reads all config from `.env`; `.env.example` contains only placeholders
- Frontend uses a single config entry point for `base_url`
- Never hardcode real keys, passwords, or server addresses in code or docs

## Docs Index

| File | Purpose |
|------|---------|
| `docs/00-global-rules.md` | Cross-step conventions (canonical) |
| `docs/DangDangDiary-technical-plan.plan.md` | Full architecture, DB schema, API overview |
| `docs/step0-env-setup-manual.md` | Manual environment setup reference |
| `docs/step1-environment-setup.md` | Docker Compose + project skeletons |
| `docs/deploy-ops.md` | Deploy/ops runbook: start-stop, restart, migrations, domain switch, the `MINIO_ENDPOINT`↔nginx `Host` signing gotcha |
| `docs/step2-auth-module.md` | SMS auth + JWT |
| `docs/step3-pet-profile.md` | Pet CRUD + profile UI |
| `docs/step4-photo-record.md` | Photo upload + validation + EXIF |
| `docs/step5-health-management.md` | Weight / routine / deworming / vaccination |
| `docs/step6-timeline.md` | Paginated timeline |
| `docs/step7-push-notification.md` | Local push notifications |
| `docs/step8-integration-polish.md` | Source hardening & automated testing (UI polish deferred to end of Phase 2) |
| `docs/phase2-step1-pet-share.md` | Phase 2: pet profile sharing (OWNER / EDITOR / VIEWER roles, share codes) |
| `docs/phase2-step2-voice-intake.md` | Phase 2: long-press voice → STT + Tongyi LLM intent extract → record drafts |
| `docs/phase2-step3-photo-auto-assign.md` | Phase 2: auto-classify uploaded photos to a pet via DashScope multimodal embedding + pgvector |
| `docs/phase2-step4-logo-splash.md` | Phase 2: brand Logo assets, Splash screen animation, AppBar / loading brand reuse |
| `docs/future-async-task-queue.md` | Future optimization: offload `_backfill_embedding` (and other slow work) to an async task queue (arq/Celery). Not scheduled. |
| `docs/future-voice-frontend-streaming.md` | Future optimization: Flutter streams PCM directly over WebSocket so STT runs while the user is still talking. Designed but not scheduled. |
| `docs/API_docs/` | Third-party API reference (Aliyun SMS, scene recognition) |

If a step doc conflicts with `00-global-rules.md`, the step doc takes precedence only when it is more specific and does not contradict a global rule.
