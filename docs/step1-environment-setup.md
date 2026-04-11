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
2. 创建 Docker Compose 编排文件，一键启动 PostgreSQL + Redis + MinIO
3. 搭建 FastAPI 后端项目骨架
4. 搭建 Flutter 前端项目骨架
5. 创建数据库模型与迁移脚本
6. 验证所有服务正常运行

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

### 创建文件: `dangdang-diary/docker-compose.yml`

```yaml
version: '3.8'

services:
  postgres:
    image: postgres:16-alpine
    container_name: dangdang-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: dangdang
      POSTGRES_USER: dangdang
      POSTGRES_PASSWORD: dangdang_dev_2024
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U dangdang"]
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
      MINIO_ROOT_USER: dangdang_minio
      MINIO_ROOT_PASSWORD: dangdang_minio_2024
    ports:
      - "9000:9000"   # S3 API
      - "9001:9001"   # Web Console
    volumes:
      - minio_data:/data
    command: server /data --console-address ":9001"

volumes:
  postgres_data:
  redis_data:
  minio_data:
```

启动命令:
```bash
cd dangdang-diary
docker compose up -d
docker compose ps  # 确认所有服务正常
```

MinIO 初始化 (创建 bucket):
```bash
# 安装 mc (MinIO Client)
wget https://dl.min.io/client/mc/release/linux-amd64/mc
chmod +x mc
sudo mv mc /usr/local/bin/

# 配置并创建 bucket
mc alias set dangdang http://localhost:9000 dangdang_minio dangdang_minio_2024
mc mb dangdang/pet-photos
mc mb dangdang/pet-thumbnails
mc mb dangdang/avatars
mc mb dangdang/ai-photos
```

---

## 3. FastAPI 后端项目骨架

### 3.1 目录结构

```
dangdang-diary/backend/
├── app/
│   ├── __init__.py
│   ├── main.py              # FastAPI 应用入口
│   ├── config.py            # 配置管理 (从环境变量读取)
│   ├── database.py          # 数据库连接与会话管理
│   ├── dependencies.py      # 通用依赖注入 (当前用户等)
│   ├── models/              # SQLAlchemy ORM 模型
│   │   ├── __init__.py
│   │   ├── user.py
│   │   ├── pet.py
│   │   ├── photo.py
│   │   ├── weight.py
│   │   ├── deworming.py
│   │   └── vaccination.py
│   ├── schemas/             # Pydantic 请求/响应 Schema
│   │   ├── __init__.py
│   │   ├── auth.py
│   │   ├── pet.py
│   │   ├── photo.py
│   │   └── health.py
│   ├── api/                 # API 路由
│   │   ├── __init__.py
│   │   └── v1/
│   │       ├── __init__.py
│   │       ├── router.py    # 汇总所有路由
│   │       ├── auth.py
│   │       ├── pets.py
│   │       ├── photos.py
│   │       └── health.py
│   ├── services/            # 业务逻辑层
│   │   ├── __init__.py
│   │   ├── auth.py
│   │   ├── sms.py
│   │   ├── storage.py       # MinIO 操作封装
│   │   └── push.py          # 推送服务封装
│   ├── utils/
│   │   ├── __init__.py
│   │   └── security.py      # JWT 生成/验证
│   └── tasks/               # 定时任务
│       ├── __init__.py
│       └── reminders.py
├── alembic/                 # 数据库迁移
│   ├── env.py
│   └── versions/
├── alembic.ini
├── requirements.txt
├── Dockerfile
├── .env                     # 本地开发环境变量 (不提交 git)
└── .env.example             # 环境变量模板
```

### 3.2 requirements.txt

```
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
```

### 3.3 核心文件内容

#### `app/config.py`

```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    APP_NAME: str = "当当日记"
    DEBUG: bool = True

    # Database
    DATABASE_URL: str = "postgresql+asyncpg://dangdang:dangdang_dev_2024@localhost:5432/dangdang"

    # Redis
    REDIS_URL: str = "redis://localhost:6379/0"

    # MinIO
    MINIO_ENDPOINT: str = "localhost:9000"
    MINIO_ACCESS_KEY: str = "dangdang_minio"
    MINIO_SECRET_KEY: str = "dangdang_minio_2024"
    MINIO_SECURE: bool = False
    MINIO_BUCKET_PHOTOS: str = "pet-photos"
    MINIO_BUCKET_THUMBNAILS: str = "pet-thumbnails"
    MINIO_BUCKET_AVATARS: str = "avatars"

    # JWT
    JWT_SECRET_KEY: str = "your-secret-key-change-in-production"
    JWT_ALGORITHM: str = "HS256"
    ACCESS_TOKEN_EXPIRE_MINUTES: int = 120
    REFRESH_TOKEN_EXPIRE_DAYS: int = 30

    # SMS (阿里云)
    ALIYUN_SMS_ACCESS_KEY_ID: str = ""
    ALIYUN_SMS_ACCESS_KEY_SECRET: str = ""
    ALIYUN_SMS_SIGN_NAME: str = "当当日记"
    ALIYUN_SMS_TEMPLATE_CODE: str = ""

    # JPush
    JPUSH_APP_KEY: str = ""
    JPUSH_MASTER_SECRET: str = ""

    class Config:
        env_file = ".env"

settings = Settings()
```

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
from fastapi import FastAPI
from app.config import settings
from app.api.v1.router import api_v1_router

@asynccontextmanager
async def lifespan(app: FastAPI):
    # 启动时: 初始化服务 (MinIO bucket 检查, 定时任务等)
    yield
    # 关闭时: 清理资源

app = FastAPI(
    title=settings.APP_NAME,
    version="1.0.0",
    lifespan=lifespan,
)

app.include_router(api_v1_router, prefix="/api/v1")

@app.get("/health")
async def health_check():
    return {"status": "ok"}
```

### 3.4 `.env.example`

```
DATABASE_URL=postgresql+asyncpg://dangdang:dangdang_dev_2024@localhost:5432/dangdang
REDIS_URL=redis://localhost:6379/0
MINIO_ENDPOINT=localhost:9000
MINIO_ACCESS_KEY=dangdang_minio
MINIO_SECRET_KEY=dangdang_minio_2024
JWT_SECRET_KEY=change-this-to-random-string
ALIYUN_SMS_ACCESS_KEY_ID=
ALIYUN_SMS_ACCESS_KEY_SECRET=
ALIYUN_SMS_SIGN_NAME=当当日记
ALIYUN_SMS_TEMPLATE_CODE=
JPUSH_APP_KEY=
JPUSH_MASTER_SECRET=
```

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
import enum
from sqlalchemy import BigInteger, String, Date, DateTime, Integer, Enum, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column, relationship
from datetime import datetime
from app.database import Base

class PetType(str, enum.Enum):
    CAT = "cat"
    DOG = "dog"

class MemberRole(str, enum.Enum):
    OWNER = "owner"
    MEMBER = "member"

class Pet(Base):
    __tablename__ = "pets"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    owner_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    name: Mapped[str] = mapped_column(String(50), nullable=False)
    pet_type: Mapped[PetType] = mapped_column(Enum(PetType), nullable=False)
    breed: Mapped[str] = mapped_column(String(50), nullable=True)
    birthday: Mapped[datetime] = mapped_column(Date, nullable=True)
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

```bash
cd backend
alembic init alembic
```

修改 `alembic/env.py`，引入所有模型并配置异步引擎:
- 设置 `target_metadata = Base.metadata`
- 引入所有 models
- 配置异步迁移

```bash
alembic revision --autogenerate -m "initial tables"
alembic upgrade head
```

---

## 6. Flutter 前端项目骨架

### 6.1 创建项目

```bash
cd dangdang-diary
flutter create --org com.dangdang --project-name dangdang_diary frontend
cd frontend
```

### 6.2 核心依赖 (pubspec.yaml 中添加)

```yaml
dependencies:
  flutter:
    sdk: flutter
  # 路由
  go_router: ^14.0.0
  # 状态管理
  flutter_riverpod: ^2.5.0
  riverpod_annotation: ^2.3.0
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
  flutter_lints: ^4.0.0
  riverpod_generator: ^2.4.0
  build_runner: ^2.4.0
  json_serializable: ^6.8.0
```

### 6.3 目录结构

```
frontend/lib/
├── main.dart                 # 应用入口
├── app.dart                  # MaterialApp 配置
├── config/
│   ├── theme.dart            # 主题配置 (简约+温馨风格)
│   ├── constants.dart        # 常量 (API 地址等)
│   └── router.dart           # 路由配置 (go_router)
├── models/                   # 数据模型 (与后端 schema 对应)
│   ├── user.dart
│   ├── pet.dart
│   ├── photo.dart
│   └── health.dart
├── services/                 # API 调用
│   ├── api_client.dart       # Dio 封装 (拦截器、Token 注入)
│   ├── auth_service.dart
│   ├── pet_service.dart
│   ├── photo_service.dart
│   └── health_service.dart
├── providers/                # Riverpod 状态管理
│   ├── auth_provider.dart
│   ├── pet_provider.dart
│   └── health_provider.dart
├── screens/                  # 页面
│   ├── auth/
│   │   └── login_screen.dart
│   ├── record/
│   │   └── record_screen.dart
│   ├── health/
│   │   ├── health_screen.dart
│   │   ├── weight_tab.dart
│   │   ├── deworming_tab.dart
│   │   └── vaccination_tab.dart
│   ├── timeline/
│   │   └── timeline_screen.dart
│   ├── ai/                   # Phase 2 预留
│   │   └── ai_screen.dart
│   └── profile/
│       ├── profile_screen.dart
│       └── pet_manage_screen.dart
├── widgets/                  # 可复用组件
│   ├── pet_selector.dart     # 顶部宠物档案选择器
│   ├── bottom_nav_bar.dart   # 底部导航栏
│   ├── date_input.dart       # 日期输入组件
│   └── loading_widget.dart
└── utils/
    ├── exif_helper.dart      # EXIF 日期提取
    └── date_formatter.dart   # 日期格式化
```

### 6.4 主题配置 (`config/theme.dart`)

```dart
import 'package:flutter/material.dart';

class AppTheme {
  // 温馨色调
  static const Color primaryColor = Color(0xFFFF8B6A);     // 温暖橘粉
  static const Color secondaryColor = Color(0xFFFFC3A0);   // 浅杏色
  static const Color backgroundColor = Color(0xFFFFF8F5);  // 暖白
  static const Color surfaceColor = Colors.white;
  static const Color textPrimary = Color(0xFF3D3D3D);      // 深灰
  static const Color textSecondary = Color(0xFF9E9E9E);    // 浅灰
  static const Color errorColor = Color(0xFFE57373);       // 柔和红

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
      cardTheme: CardTheme(
        elevation: 1,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
```

### 6.5 路由配置 (`config/router.dart`)

底部导航栏 5 个 Tab:
1. `/record` - 记录 (默认页)
2. `/health` - 健康
3. `/timeline` - 时间轴
4. `/ai` - AI (Phase 2, 先显示"敬请期待")
5. `/profile` - 我的

使用 `go_router` 的 `StatefulShellRoute` 实现底部导航栏切换时保持页面状态。

### 6.6 底部导航栏布局

```
┌──────────────────────────────────┐
│         (页面内容区域)            │
│                                  │
│                                  │
│                                  │
├──────────────────────────────────┤
│  记录  │  健康  │ 时间轴 │  AI  │ 我的 │
└──────────────────────────────────┘
```

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

- [ ] `docker compose up -d` 可以正常启动 PostgreSQL、Redis、MinIO
- [ ] 访问 `http://localhost:9001` 可以打开 MinIO Web 控制台
- [ ] PostgreSQL 中已创建所有数据表 (通过 Alembic 迁移)
- [ ] `uvicorn app.main:app --reload` 启动后端，访问 `http://localhost:8000/health` 返回 `{"status": "ok"}`
- [ ] 访问 `http://localhost:8000/docs` 可以看到 Swagger API 文档
- [ ] `flutter run` 可以在 Android 模拟器/设备上启动 APP
- [ ] APP 显示底部导航栏，可以切换 5 个 Tab (AI Tab 显示占位页)
- [ ] 整体 UI 风格为暖色调 (橘粉+暖白)

---

## 9. 注意事项

- `.env` 文件不要提交到 git，只提交 `.env.example`
- 开发阶段后端直接在本地跑 (不放 Docker)，方便热重载
- Flutter 开发时使用 `flutter run` 连接真机或模拟器
- 先不要接入短信和推送服务，那是后续步骤的事
