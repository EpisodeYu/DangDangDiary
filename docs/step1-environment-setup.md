# Step 1: 开发环境搭建与项目骨架

## 项目背景

「当当日记」是一个宠物日记 APP，支持记录宠物照片、体重、驱虫、疫苗等信息，后续支持 AI 功能。

技术栈:

- **前端**: Flutter 3.x (Dart)
- **后端**: Python 3.11+ FastAPI
- **数据库**: PostgreSQL 16
- **缓存**: Redis 7
- **对象存储**: MinIO (S3 兼容，开发阶段自建)
- **反向代理**: Nginx
- **容器化**: Docker + Docker Compose

开发服务器: Ubuntu, 2C4G, 50G 存储

---

## 本步骤目标

1. 在 Ubuntu 上安装所有开发环境依赖
2. 创建 Docker Compose 编排文件，一键启动 Nginx + PostgreSQL + Redis + MinIO
3. 搭建 FastAPI 后端项目骨架，并约定统一的配置与错误响应基线
4. 搭建 Flutter 前端项目骨架，包含主题、路由、Riverpod 基础设施、API 客户端骨架与 5 个 Tab 占位页
5. 创建 Phase 1 核心数据库模型与 Alembic 初始迁移
6. 验证真机可以通过统一入口访问后端，前端可以正常启动

---

## 当前仓库说明

本仓库中的 Step 1 已经完成。本文件的用途有两个：

1. 说明 Step 1 交付物的设计目标。
2. 记录当前仓库里已经落地的代码骨架，避免后续 agent 把“后续步骤才会补齐的目录或能力”误认为已经存在。

因此，当你基于当前仓库继续开发时：

- 不要重复执行 `flutter create` 覆盖 `frontend/`
- 不要重复执行 `alembic init` 覆盖 `backend/alembic/`
- 目录结构、依赖版本、配置字段优先以仓库中的实际文件为准

## 项目级默认约定

以下约定从 Step 1 开始生效，后续所有步骤默认遵守，除非某个步骤明确说明例外。

### 统一入口与客户端访问

- 真机只访问一个统一入口，不直接访问 FastAPI 或 MinIO 内部地址
- 统一入口由 Nginx 提供，推荐使用 `http://YOUR_SERVER_IP`
- 路径约定:
  - `/api/...` -> FastAPI
  - `/media/...` -> 媒体访问路径
- 面向手机客户端返回的 URL 不得使用 `minio:9000`、`minio-server:9000` 等内部地址

### 配置与敏感信息

- 后端与前端都必须有清晰的配置入口，不允许把地址和敏感值散落写死在代码中
- `.env.example` 只能保留占位符，不得出现真实 AccessKey、Secret 或固定密码

### API 约定

- 接口字段统一使用 `snake_case`
- 列表接口保留业务语义 key，例如 `pets`、`photos`、`weights`
- 分页统一使用 `page` + `page_size`
- 创建/更新成功默认返回最新完整对象
- 删除成功统一返回 `204 No Content`
- 列表筛选为空时返回 `200 + 空数组`

### 错误响应约定

- 业务错误统一为结构化格式: `code` + `message` + `details`
- 输入不合法统一归类为 `400`
- 无权限访问统一使用 `403`
- 如果使用 FastAPI / Pydantic 默认校验，需要注册统一异常处理器，将 `RequestValidationError` 转换为 `400` 结构化错误

### 媒体与时间约定

- HEIC/HEIF 由前端先转为 JPEG 后再上传
- 后端稳定支持 JPG / PNG / WEBP
- 列表接口直接返回可显示的缩略图 URL，大图查看时再单独请求原图 URL
- 时间戳统一按 UTC 存储；生日、拍摄日期、记录日期等仅表示日期的字段继续使用 `date`

---

## 1. 开发环境安装

### 1.1 系统基础工具

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y git curl wget unzip build-essential
```

### 1.2 Docker + Docker Compose

```bash
# 安装 Docker
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo usermod -aG docker $USER
# 注销重新登录后生效

# Docker Compose (v2, 已包含在 Docker 中)
docker compose version
```

### 1.3 Python 3.11+

```bash
sudo apt install -y python3.11 python3.11-venv python3-pip
# 或使用 pyenv 管理版本
```

### 1.4 Flutter SDK

```bash
# 下载 Flutter SDK
cd ~
git clone https://github.com/flutter/flutter.git -b stable
export PATH="$HOME/flutter/bin:$PATH"
# 添加到 ~/.bashrc

# 安装 Android 命令行工具
sudo apt install -y openjdk-17-jdk
flutter doctor  # 检查环境
flutter config --no-analytics

# Android SDK (通过 Android Studio 或 cmdline-tools 安装)
# 下载 cmdline-tools: https://developer.android.com/studio#command-tools
mkdir -p ~/Android/Sdk/cmdline-tools
# 解压 cmdline-tools 到上述目录
# 运行 sdkmanager 安装必要组件:
# sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"
```

### 1.5 开发工具

```bash
# 已使用 Cursor IDE
# 安装 Flutter 和 Dart 插件
# 安装 Python 插件
```

---

## 2. Docker Compose 编排

本节描述的是当前仓库已经落地的基础设施文件，而不是新的建议草稿。

### 当前文件: `docker-compose.yml`

```yaml
services:
  nginx:
    image: nginx:1.27-alpine
    container_name: dangdang-nginx
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    depends_on:
      - minio

  postgres:
    image: postgres:16-alpine
    container_name: dangdang-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: dangdang
      POSTGRES_USER: ${DB_USER:-dangdang}
      POSTGRES_PASSWORD: ${DB_PASSWORD:-dangdang_dev}
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U ${DB_USER:-dangdang}"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    container_name: dangdang-redis
    restart: unless-stopped
    ports:
      - "6379:6379"
    volumes:
      - redis_data:/data
    command: redis-server --appendonly yes

  minio:
    image: minio/minio:latest
    container_name: dangdang-minio
    restart: unless-stopped
    environment:
      MINIO_ROOT_USER: ${MINIO_ROOT_USER:-minioadmin}
      MINIO_ROOT_PASSWORD: ${MINIO_ROOT_PASSWORD:-minioadmin123}
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - minio_data:/data
    command: server /data --console-address ":9001"

volumes:
  postgres_data:
  redis_data:
  minio_data:
```

当前实现说明：

- 开发阶段后端仍然直接在宿主机运行 `uvicorn`，并不放进 Docker。
- `nginx` 只依赖 `minio`，因为 `/api/`、`/docs`、`/openapi.json` 都反代到宿主机上的 FastAPI，而不是容器里的 FastAPI。
- `extra_hosts: host.docker.internal:host-gateway` 是为了让 Linux 下的 Nginx 容器也能访问宿主机上的 `8000` 端口。
- Compose 使用 `${VAR:-默认值}` 提供本地开发默认凭据，因此文档不要再假设 `docker-compose.yml` 里全是 `YOUR_*` 占位符。

启动命令：

```bash
cd ~/DangDangDiary
docker compose up -d
docker compose ps
```

### 当前文件: `nginx/nginx.conf`

```nginx
events {}

http {
  server {
    listen 80;
    client_max_body_size 20m;

    location /api/ {
      proxy_pass http://host.docker.internal:8000/api/;
      proxy_set_header Host $host;
      proxy_set_header X-Real-IP $remote_addr;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /docs {
      proxy_pass http://host.docker.internal:8000/docs;
      proxy_set_header Host $host;
    }

    location /openapi.json {
      proxy_pass http://host.docker.internal:8000/openapi.json;
      proxy_set_header Host $host;
    }

    location /media/ {
      proxy_pass http://minio:9000/;
      proxy_set_header Host $host;
    }
  }
}
```

说明：

- 当前代码中，`/media/` 是由 Nginx 直接反代到 Compose 网络里的 `minio:9000`，不是宿主机的 `9000`。
- 这意味着后端和前端面向用户返回的地址仍然应该是 `http://YOUR_SERVER_IP/media/...`，但容器内部的代理目标是 `minio:9000`。
- 面向真机时，推荐只暴露 `http://YOUR_SERVER_IP`，而不是把 `:8000` 和 `:9000` 直接写进前端配置。

MinIO 初始化（创建 bucket）：

```bash
# 安装 mc (MinIO Client)
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# 配置并创建 bucket
mc alias set dangdang http://127.0.0.1:9000 MINIO_ROOT_USER MINIO_ROOT_PASSWORD
mc mb dangdang/pet-photos
mc mb dangdang/pet-thumbnails
mc mb dangdang/avatars
mc mb dangdang/ai-photos
```

---

## 3. FastAPI 后端项目骨架

### 3.1 目录结构

```text
DangDangDiary/backend/
├── app/
│   ├── api/
│   │   └── v1/
│   │       ├── auth.py
│   │       ├── health.py
│   │       ├── pets.py
│   │       ├── photos.py
│   │       └── router.py
│   ├── models/
│   │   ├── __init__.py
│   │   ├── deworming.py
│   │   ├── pet.py
│   │   ├── photo.py
│   │   ├── user.py
│   │   ├── vaccination.py
│   │   └── weight.py
│   ├── schemas/
│   │   ├── auth.py
│   │   ├── common.py
│   │   ├── health.py
│   │   ├── pet.py
│   │   └── photo.py
│   ├── config.py
│   ├── database.py
│   ├── dependencies.py
│   └── main.py
├── alembic/
│   ├── env.py
│   └── versions/
│       └── fc219291de06_initial_tables.py
├── alembic.ini
├── requirements.txt
├── Dockerfile
└── .env.example
```

说明：

- 当前 Step 1 已落地的是“可启动的最小后端骨架”。
- `app/services/`、`app/utils/`、`app/tasks/` 这些目录尚未出现在当前仓库中，它们属于后续步骤可能新增的扩展结构，不要误认为 Step 1 已经创建。
- `app/api/v1/auth.py`、`pets.py`、`photos.py`、`health.py` 已经存在，但目前仍主要承担路由骨架和占位作用，真实业务会在后续步骤补全。

### 3.2 requirements.txt

```text
fastapi==0.115.0
uvicorn[standard]==0.30.0
sqlalchemy==2.0.35
asyncpg==0.29.0
alembic==1.13.0
pydantic==2.9.0
pydantic-settings==2.5.0
python-jose[cryptography]==3.3.0
passlib[bcrypt]==1.7.4
redis==5.1.0
minio==7.2.9
python-multipart==0.0.12
httpx==0.27.0
apscheduler==3.10.4
pillow==10.4.0
alibabacloud-dypnsapi20170525>=2.0.0
alibabacloud-imagerecog20190930>=2.0.0
```

说明：

- Step 1 已经把 Phase 1 后续会用到的核心依赖预装进 `backend/requirements.txt`。
- 即使短信、图片识别等业务要到后续步骤才真正实现，相关 SDK 依赖也已经提前加入。

### 3.3 核心文件内容

#### `app/config.py`

```python
from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    APP_NAME: str = "当当日记"
    DEBUG: bool = True
    PUBLIC_BASE_URL: str = "http://YOUR_SERVER_IP"

    # Database
    DATABASE_URL: str = "postgresql+asyncpg://dangdang:dangdang_dev@127.0.0.1:5432/dangdang"

    # Redis
    REDIS_URL: str = "redis://127.0.0.1:6379/0"

    # MinIO (internal access)
    MINIO_ENDPOINT: str = "127.0.0.1:9000"
    MINIO_ACCESS_KEY: str = "minioadmin"
    MINIO_SECRET_KEY: str = "minioadmin123"
    MINIO_SECURE: bool = False
    MINIO_BUCKET_PHOTOS: str = "pet-photos"
    MINIO_BUCKET_THUMBNAILS: str = "pet-thumbnails"
    MINIO_BUCKET_AVATARS: str = "avatars"

    # JWT
    JWT_SECRET_KEY: str = "your-secret-key-change-in-production"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 120
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30

    # Aliyun AccessKey (SMS + image recognition)
    ALIYUN_ACCESS_KEY_ID: str = ""
    ALIYUN_ACCESS_KEY_SECRET: str = ""

    # SMS (Aliyun Dypnsapi)
    ALIYUN_SMS_SIGN_NAME: str = "速通互联验证码"
    ALIYUN_SMS_TEMPLATE_CODE: str = "100001"

    # Image recognition (Aliyun RecognizeScene)
    ALIYUN_IMAGERECOG_ENDPOINT: str = "imagerecog.cn-shanghai.aliyuncs.com"
    ALIYUN_IMAGERECOG_REGION: str = "cn-shanghai"

    model_config = {"env_file": ".env"}


settings = Settings()
```

补充约定:

- 客户端可见的 URL 统一基于 `PUBLIC_BASE_URL` 生成
- 后端内部访问 MinIO 时使用 `MINIO_ENDPOINT`
- 需要写入数据库的时间戳统一按 UTC 处理

#### `app/database.py`

```python
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession, async_sessionmaker
from sqlalchemy.orm import DeclarativeBase

from app.config import settings

engine = create_async_engine(settings.DATABASE_URL, echo=settings.DEBUG)
async_session_maker = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)

class Base(DeclarativeBase):
    pass

async def get_db():
    async with async_session_maker() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
```

#### `app/main.py`

```python
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from app.config import settings
from app.api.v1.router import api_v1_router


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup: initialize services (MinIO bucket check, scheduled tasks, etc.)
    yield
    # Shutdown: cleanup resources


app = FastAPI(
    title=settings.APP_NAME,
    version="1.0.0",
    lifespan=lifespan,
)


@app.exception_handler(RequestValidationError)
async def validation_exception_handler(request: Request, exc: RequestValidationError):
    return JSONResponse(
        status_code=400,
        content={
            "code": "VALIDATION_ERROR",
            "message": "请求参数校验失败",
            "details": exc.errors(),
        },
    )


app.include_router(api_v1_router, prefix="/api/v1")


@app.get("/health")
async def health_check():
    return {"status": "ok"}
```

补充说明：

- 当前代码已经在 Step 1 就注册了 `RequestValidationError` 的统一异常处理器。
- 当前代码已经挂载了 `auth`、`pets`、`photos`、`health` 四组 v1 路由骨架。

### 3.4 `backend/.env.example`

```text
PUBLIC_BASE_URL=http://YOUR_SERVER_IP
DATABASE_URL=postgresql+asyncpg://YOUR_DB_USER:YOUR_DB_PASSWORD@127.0.0.1:5432/dangdang
REDIS_URL=redis://127.0.0.1:6379/0
MINIO_ENDPOINT=127.0.0.1:9000
MINIO_ACCESS_KEY=YOUR_MINIO_ACCESS_KEY
MINIO_SECRET_KEY=YOUR_MINIO_SECRET_KEY
JWT_SECRET_KEY=CHANGE_THIS_TO_A_RANDOM_STRING
ALIYUN_ACCESS_KEY_ID=YOUR_ALIYUN_ACCESS_KEY_ID
ALIYUN_ACCESS_KEY_SECRET=YOUR_ALIYUN_ACCESS_KEY_SECRET
ALIYUN_SMS_SIGN_NAME=速通互联验证码
ALIYUN_SMS_TEMPLATE_CODE=100001
ALIYUN_IMAGERECOG_ENDPOINT=imagerecog.cn-shanghai.aliyuncs.com
ALIYUN_IMAGERECOG_REGION=cn-shanghai
```

说明：

- 当前仓库中的模板文件位于 `backend/.env.example`，不是仓库根目录。
- 后端 `.env` 只服务于 FastAPI 配置读取；Docker Compose 使用的是根目录环境变量或默认值机制。

---

## 4. 数据库模型 (SQLAlchemy ORM)

### `app/models/user.py`

```python
from sqlalchemy import BigInteger, String, DateTime
from sqlalchemy.orm import Mapped, mapped_column, relationship
from datetime import datetime
from app.database import Base

class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    phone: Mapped[str] = mapped_column(String(20), unique=True, nullable=False, index=True)
    nickname: Mapped[str] = mapped_column(String(50), nullable=True)
    avatar_url: Mapped[str] = mapped_column(String(500), nullable=True)
    # Phase 2: 微信登录
    wechat_openid: Mapped[str] = mapped_column(String(100), nullable=True, unique=True)
    wechat_unionid: Mapped[str] = mapped_column(String(100), nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
```

### `app/models/pet.py`

```python
from datetime import date, datetime
import enum
from sqlalchemy import BigInteger, String, Date, DateTime, Integer, Enum, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column, relationship
from app.database import Base

class PetType(str, enum.Enum):
    CAT = "cat"
    DOG = "dog"

class MemberRole(str, enum.Enum):
    OWNER = "owner"
    EDITOR = "editor"
    VIEWER = "viewer"

class Pet(Base):
    __tablename__ = "pets"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    owner_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(50), nullable=False)
    pet_type: Mapped[PetType] = mapped_column(Enum(PetType), nullable=False)
    breed: Mapped[str] = mapped_column(String(50), nullable=True)
    birthday: Mapped[date] = mapped_column(Date, nullable=True)
    avatar_url: Mapped[str] = mapped_column(String(500), nullable=True)
    invite_code: Mapped[str] = mapped_column(String(20), unique=True, nullable=False)
    internal_deworming_cycle_days: Mapped[int] = mapped_column(Integer, nullable=True)
    external_deworming_cycle_days: Mapped[int] = mapped_column(Integer, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)

class PetMember(Base):
    __tablename__ = "pet_members"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    role: Mapped[MemberRole] = mapped_column(Enum(MemberRole), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
```

> 当前 main 分支在 Phase 2 Step 1 中已经按这套 `owner/editor/viewer` 角色落地；后续还新增了 `pet_share_codes` 表与分享接口，详见 `docs/phase2-step1-pet-share.md`。

### `app/models/photo.py`

```python
from sqlalchemy import BigInteger, String, Date, DateTime, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column
from datetime import datetime, date
from app.database import Base

class Photo(Base):
    __tablename__ = "photos"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False, index=True)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    storage_key: Mapped[str] = mapped_column(String(500), nullable=False)
    thumbnail_key: Mapped[str] = mapped_column(String(500), nullable=True)
    taken_at: Mapped[date] = mapped_column(Date, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
```

### `app/models/weight.py`

```python
from sqlalchemy import BigInteger, Numeric, Date, DateTime, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column
from datetime import datetime, date
from decimal import Decimal
from app.database import Base

class Weight(Base):
    __tablename__ = "weights"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False, index=True)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    weight_kg: Mapped[Decimal] = mapped_column(Numeric(5, 2), nullable=False)
    recorded_at: Mapped[date] = mapped_column(Date, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
```

### `app/models/deworming.py`

```python
import enum
from sqlalchemy import BigInteger, Date, DateTime, Enum, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column
from datetime import datetime, date
from app.database import Base

class DewormingType(str, enum.Enum):
    INTERNAL = "internal"
    EXTERNAL = "external"

class Deworming(Base):
    __tablename__ = "dewormings"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False, index=True)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    deworming_type: Mapped[DewormingType] = mapped_column(Enum(DewormingType), nullable=False)
    dewormed_at: Mapped[date] = mapped_column(Date, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
```

### `app/models/vaccination.py`

```python
from sqlalchemy import BigInteger, String, Date, DateTime, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column
from datetime import datetime, date
from app.database import Base

class Vaccination(Base):
    __tablename__ = "vaccinations"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False, index=True)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    vaccine_type: Mapped[str] = mapped_column(String(100), nullable=False)
    vaccinated_at: Mapped[date] = mapped_column(Date, nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
```

### `app/models/__init__.py`

```python
from app.models.user import User
from app.models.pet import Pet, PetMember, PetType, MemberRole
from app.models.photo import Photo
from app.models.weight import Weight
from app.models.deworming import Deworming, DewormingType
from app.models.vaccination import Vaccination
```

---

## 5. 数据库迁移 (Alembic)

当前仓库中的 Alembic 已经初始化完成，不要重复执行 `alembic init alembic`。

当前状态：

- `backend/alembic/env.py` 已配置异步迁移。
- `target_metadata = Base.metadata` 已接好。
- 所有模型已在 `env.py` 中引入。
- 初始迁移文件已经存在：`backend/alembic/versions/fc219291de06_initial_tables.py`

日常使用命令：

```bash
cd backend
alembic upgrade head
```

如果你在 Step 1 之后又新增了模型字段，再执行：

```bash
cd backend
alembic revision --autogenerate -m "describe your change"
alembic upgrade head
```

---

## 6. Flutter 前端项目骨架

### 6.1 创建项目

```bash
cd ~/DangDangDiary
flutter create --org com.dangdang --project-name dangdang_diary frontend
cd frontend
```

如果你是在当前仓库上继续开发，请不要重复执行这一步；当前 `frontend/` 已经创建完成。

### 6.2 核心依赖 (pubspec.yaml 中添加)

```yaml
dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  # 路由
  go_router: ^14.0.0
  # 状态管理基础设施
  flutter_riverpod: ^2.5.0
  # 网络请求
  dio: ^5.7.0
  # 本地存储 (Token 持久化)
  shared_preferences: ^2.3.0
  # 图片选择
  image_picker: ^1.1.0
  # 图片压缩 (生成缩略图)
  flutter_image_compress: ^2.3.0
  # EXIF 读取
  exif: ^3.3.0
  # 图片缓存与显示
  cached_network_image: ^3.4.0
  # 日期选择
  intl: ^0.19.0
  # 下拉刷新
  pull_to_refresh: ^2.0.0
  # 权限管理
  permission_handler: ^11.3.0
  # 图片查看器
  photo_view: ^0.15.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^6.0.0
```

说明：

- 当前仓库里还没有引入 `riverpod_generator`、`build_runner`、`json_serializable` 等代码生成相关依赖。
- Step 1 只需要 `ProviderScope` 级别的 Riverpod 基础设施，不要求已经存在业务 Provider。

### 6.3 目录结构

```text
frontend/lib/
├── main.dart                 # 应用入口
├── app.dart                  # MaterialApp 配置
├── config/
│   ├── constants.dart        # 基础常量与 API 前缀
│   ├── router.dart           # go_router 路由配置
│   └── theme.dart            # 暖色主题
├── screens/
│   ├── auth/
│   │   └── login_screen.dart
│   ├── ai/
│   │   └── ai_screen.dart
│   ├── health/
│   │   └── health_screen.dart
│   └── profile/
│       └── profile_screen.dart
│   ├── record/
│   │   └── record_screen.dart
│   └── timeline/
│       └── timeline_screen.dart
├── services/
│   └── api_client.dart       # Dio 单例 + Token 注入骨架
└── widgets/
    └── main_scaffold.dart    # 底部导航壳
```

说明：

- 当前 Step 1 已落地的是“最小可运行前端骨架”。
- `models/`、`providers/`、`utils/`、`auth_service.dart`、`pet_manage_screen.dart` 等目录或文件尚未在当前仓库中创建。
- 这些更细的分层会在后续具体业务步骤中按需补齐，不应被视为 Step 1 已有能力。

### 6.4 主题配置 (`config/theme.dart`)

```dart
import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Warm color palette
  static const Color primaryColor = Color(0xFFFF8B6A);
  static const Color secondaryColor = Color(0xFFFFC3A0);
  static const Color backgroundColor = Color(0xFFFFF8F5);
  static const Color surfaceColor = Colors.white;
  static const Color textPrimary = Color(0xFF3D3D3D);
  static const Color textSecondary = Color(0xFF9E9E9E);
  static const Color errorColor = Color(0xFFE57373);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primaryColor,
        brightness: Brightness.light,
        surface: backgroundColor,
      ),
      scaffoldBackgroundColor: backgroundColor,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: Colors.white,
        selectedItemColor: primaryColor,
        unselectedItemColor: textSecondary,
        type: BottomNavigationBarType.fixed,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
      ),
      cardTheme: CardThemeData(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
```

### 6.5 路由配置 (`config/router.dart`)

当前仓库里的路由结构：

- `/login`：登录页，占位，Step 2 实现
- `/record`：记录页，占位，默认页
- `/health`：健康页，占位
- `/timeline`：时间轴，占位
- `/ai`：AI 页，占位
- `/profile`：我的，占位

当前实现使用 `go_router` 的 `StatefulShellRoute.indexedStack` 来保持 5 个底部 Tab 的页面状态，并把 `/login` 放在 shell 之外。

当前代码中的 `initialLocation` 是 `/record`，不是 `/login`。

### 6.6 底部导航栏布局

```text
┌──────────────────────────────────┐
│         (页面内容区域)            │
│                                  │
│                                  │
│                                  │
├──────────────────────────────────┤
│  记录  │  健康  │ 时间轴 │  AI  │ 我的 │
└──────────────────────────────────┘
```

当前实现由 `frontend/lib/widgets/main_scaffold.dart` 提供底部导航壳，而不是单独的 `bottom_nav_bar.dart` 文件。

### 6.7 当前前端骨架补充说明

- `main.dart` 已经用 `ProviderScope` 包裹应用，说明 Riverpod 基础设施已接入。
- `app.dart` 已经使用 `MaterialApp.router`、`AppTheme.lightTheme` 与 `routerConfig: router`。
- `services/api_client.dart` 已经具备 Dio 单例、`baseUrl`、`apiPrefix` 与 access token 注入能力，但 token 刷新逻辑仍留待 Step 2。
- `frontend/test/widget_test.dart` 已经包含一个基础测试，用于验证底部 5 个 Tab 文案能够渲染。
- `config/constants.dart` 当前通过 `String.fromEnvironment('BASE_URL')` 读取后端入口，并带有一个当前开发环境默认值。后续 agent 不应依赖具体默认 IP，应优先通过 `--dart-define=BASE_URL=...` 覆盖。

---

## 7. 后端 Dockerfile

```dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

注意: 开发阶段直接在本地运行 `uvicorn app.main:app --reload`，不需要 Docker 运行后端。

---

## 8. 验收标准

- [ ] `docker compose up -d` 可以正常启动 Nginx、PostgreSQL、Redis、MinIO
- [ ] 访问 `http://localhost:9001` 可以打开 MinIO Web 控制台
- [ ] PostgreSQL 中已创建所有数据表 (通过 Alembic 迁移)
- [ ] `uvicorn app.main:app --reload` 启动后端，访问 `http://localhost:8000/health` 返回 `{"status": "ok"}`
- [ ] 真机访问 `http://YOUR_SERVER_IP/api/v1/...`、`http://YOUR_SERVER_IP/docs` 与 `http://YOUR_SERVER_IP/media/...` 链路正常
- [ ] `flutter run` 可以在 Android 真机上启动 APP
- [ ] APP 显示底部导航栏，可以切换 5 个 Tab，且 `/record` 为默认页、AI Tab 显示占位页
- [ ] 整体 UI 风格为暖色调 (橘粉+暖白)
- [ ] `frontend/test/widget_test.dart` 至少能验证底部 5 个 Tab 文案渲染
- [ ] `.env.example` 中不包含真实密钥或固定生产密码

---

## 9. 注意事项

- `backend/.env.example` 是当前后端环境变量模板，不是仓库根目录 `.env.example`
- `.env` 文件不要提交到 git，只提交 `.env.example`
- 开发阶段后端直接在本地跑 `uvicorn`，Docker 主要承载 PostgreSQL、Redis、MinIO 与 Nginx
- 当前 Nginx 配置中，`/media/` 反代的是 Compose 网络里的 `minio:9000`
- Flutter 开发时使用 `flutter run` 连接真机，并优先通过 `--dart-define=BASE_URL=http://YOUR_SERVER_IP` 传入统一入口
- Step 1 只保证前后端骨架、路由、主题、数据库模型和基础配置到位；业务级 `services/`、`providers/`、认证实现、媒体处理和推送逻辑都在后续步骤补齐
