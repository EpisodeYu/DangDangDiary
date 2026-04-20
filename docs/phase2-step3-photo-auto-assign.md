# Phase 2 - Step 3: 上传照片自动归类到档案

## 项目背景

Phase 1 的记录页（[frontend/lib/screens/record/record_screen.dart](../frontend/lib/screens/record/record_screen.dart)）要求用户**先在 AppBar 里选中一只宠物**，然后选的所有照片都归属这只宠物。对"一家养多只"的用户来说，这个交互极其反人类：

- 从相册一次挑了 5 张，3 张是咪咪、2 张是橘子，只能分两次上传；
- 宠物选错时，已经上传完的一批无法回滚；
- 对刚入坑的新用户来说，"选择宠物"是一个多余的、模态的认知负担。

本步骤把"选宠物"从用户手里挪到模型手里：用户选完照片直接就看到每张右上/右侧都有一个预填好的**宠物 Chip**（识别结果），Chip 可点击改；松手后"记录完成"按钮按宠物分组落库，一次记录可以跨多只宠物，一键完成。

**识别方案**：DashScope 多模态 Embedding + Postgres pgvector + 余弦相似度，不经过 LLM，单次成本 ≈ ¥0.001、延迟 300-600ms。

**前置依赖**：Phase 1 全部完成，Phase 2 Step 1（成员角色 OWNER / EDITOR / VIEWER）已经落库；本步骤**不**依赖 Step 2（语音）的实现，但两个 Step 共用同一个 DashScope API Key，建议 Step 2 先接完再做本步。

---

## 本步骤目标

1. **后端**：新增 `pet_photo_embeddings` 表（pgvector + ivfflat 索引）、新增 `POST /api/v1/photos/classify` 单接口；在现有 `POST /pets/{pet_id}/photos` 成功后**异步回流**照片 embedding，无需改该接口的响应。
2. **后端**：新增 `services/embedding.py`（DashScope `multimodal-embedding-v1` 封装）、`services/pet_centroid.py`（向量读写 + 判决 + Redis 缓存）。
3. **基础设施**：`docker-compose.yml` 的 postgres 镜像从 `postgres:16-alpine` 换成 `pgvector/pgvector:pg16`；Alembic 迁移里 `CREATE EXTENSION vector`。
4. **前端**：记录页大改——去掉 AppBar 的 `PetSelector`，每张照片卡片下方的"日期行"右侧增加 `PetChipDropdown`；选照片完成后并发调 classify，Chip 自动填入识别结果；提交按 `pet_id` 分组，对每组调一次现有 `PhotoService.uploadPhotos`。
5. **UX 细节**：识别超时 / 无参照档案 / 低置信度统一走"Chip 显示「选择宠物」"；用户改过的 Chip 在提交后把这张照片标成 `user_corrected` 入池作为强信号。

---

## 0. 与既有约定的关系

- **全局规则 §4 API 约定**（[docs/00-global-rules.md](00-global-rules.md)）：snake_case、错误结构 `{code, message, details}`。新接口严格对齐。
- **全局规则 §媒体处理**：前端已有 JPEG 转换与场景识别（`PetClassifier`）管线，本步在其**下游**加一步"是哪一只宠物"的细粒度识别，不替换也不干扰已有"是否像猫狗"的兜底。
- **Phase 2 Step 1 权限**：classify 候选池只取调用方有 `EDITOR` 及以上角色的宠物（拿到识别结果也不能越权上传），复用 `services/pet.get_pet_membership` 不重写。
- **复用而非重写 `POST /pets/{pet_id}/photos`**：保持该接口签名不变；"跨宠物记录"在前端按宠物拆成多次调用。后端将来若要做原子批量，走独立版本号，不破坏现有客户端。

---

## 1. 整体链路

```
用户选完 N 张照片（相册 / 拍照）
    │
    ▼
前端为每张照片本地跑 PetClassifier（cat/dog 过滤，已有逻辑）
    │
    ▼
对过滤通过的 N' 张并发调 POST /api/v1/photos/classify
    │
    ├─ 服务端压缩 → DashScope multimodal-embedding-v1 → vector(1024)
    ├─ 拿调用方 pet 集合的 centroid → cosine sim Top-3
    └─ 判决：Top-1 ≥ 0.78 且与 Top-2 差 ≥ 0.05 → {pet_id, confidence}
                                            否则 → null
    │
    ▼
前端按 file_index 回填每张照片的 PetChipDropdown；用户可改
    │
    ▼ 点「记录完成」
按 pet_id 分组 → 对每组调 POST /pets/{pet_id}/photos（旧接口）
    │
    ▼
后端 create_photo 成功后，把这张照片 embedding
    用 BackgroundTask 异步写入 pet_photo_embeddings
    （source = user_corrected 如果该 chip 被用户改过，否则 user_uploaded）
```

---

## 2. 基础设施：pgvector

### 2.1 Postgres 镜像替换

[docker-compose.yml](../docker-compose.yml) 的 `postgres` 服务：

```yaml
  postgres:
    image: pgvector/pgvector:pg16         # ← 原为 postgres:16-alpine
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
```

`pgvector/pgvector:pg16` 是 pgvector 官方镜像，基于 `postgres:16`（非 alpine）。**本地已有数据卷的开发机**：先 `docker compose down -v` 再 `docker compose up -d` 重建（pgvector 镜像与 alpine 镜像数据目录不兼容，不能原地替换）。生产首次上线同理——本步骤的 alembic 迁移不是原地升级，建议搭配数据库备份窗口执行。

### 2.2 后端依赖

[backend/requirements.txt](../backend/requirements.txt) 新增：

```
pgvector==0.3.*
openai>=1.40,<2   # 已用于 Step 2 语音意图；若未装也在此引入
httpx>=0.27       # 若未装
```

`pgvector` Python 包提供 SQLAlchemy 的 `Vector` 类型。

---

## 3. 数据模型

### 3.1 新增 `PetPhotoEmbedding`

新建 [backend/app/models/pet_photo_embedding.py](../backend/app/models/pet_photo_embedding.py)：

```python
import enum
from datetime import datetime

from pgvector.sqlalchemy import Vector
from sqlalchemy import BigInteger, DateTime, Enum, ForeignKey
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base
from app.utils.time import utcnow

EMBEDDING_DIM = 1024  # DashScope multimodal-embedding-v1


class EmbeddingSource(str, enum.Enum):
    PET_AVATAR = "pet_avatar"          # 档案头像自动入池（预留，暂不使用）
    USER_UPLOADED = "user_uploaded"    # 正常上传时回流
    USER_CORRECTED = "user_corrected"  # 用户把错的识别 chip 改对 / bootstrap 样本


class PetPhotoEmbedding(Base):
    __tablename__ = "pet_photo_embeddings"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False, index=True)
    photo_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("photos.id"), nullable=True)
    embedding: Mapped[list[float]] = mapped_column(Vector(EMBEDDING_DIM), nullable=False)
    source: Mapped[EmbeddingSource] = mapped_column(Enum(EmbeddingSource), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)
```

> `photo_id` nullable 是为了兼容 bootstrap 样本场景——用户上传完、照片已入库，但若后端回流那一步失败（例如 DashScope 超时），仍可以后补 embedding（`photo_id` 关联到已有 photo），反之若之后删了 photo 也不会 cascade 删 embedding（`ON DELETE SET NULL`，见迁移 §4）。

### 3.2 模型注册

[backend/app/models/\_\_init\_\_.py](../backend/app/models/__init__.py) 追加：

```python
from app.models.pet_photo_embedding import PetPhotoEmbedding, EmbeddingSource
```

`__all__` 里补 `"PetPhotoEmbedding"`、`"EmbeddingSource"`。[backend/alembic/env.py](../backend/alembic/env.py) 若不是从 `app.models` 导入，则额外 import 一下确保 `Base.metadata` 见到新表。

---

## 4. Alembic 迁移

新建 `backend/alembic/versions/f6a7b8c9d0e1_phase2_pet_photo_embeddings.py`：

```python
"""phase2: pet photo embeddings for auto-assign

Revision ID: f6a7b8c9d0e1
Revises: <语音迁移的 revision，实现完 Step 2 再填>
Create Date: 2026-04-21 00:00:00.000000
"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa
from pgvector.sqlalchemy import Vector


revision: str = 'f6a7b8c9d0e1'
down_revision: Union[str, None] = '<step2-voice-intake-revision>'  # 按实际填
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    op.execute("CREATE EXTENSION IF NOT EXISTS vector")

    op.create_table(
        'pet_photo_embeddings',
        sa.Column('id', sa.BigInteger(), autoincrement=True, nullable=False),
        sa.Column('pet_id', sa.BigInteger(), nullable=False),
        sa.Column('photo_id', sa.BigInteger(), nullable=True),
        sa.Column('embedding', Vector(1024), nullable=False),
        sa.Column('source',
                  sa.Enum('pet_avatar', 'user_uploaded', 'user_corrected',
                          name='embeddingsource'),
                  nullable=False),
        sa.Column('created_at', sa.DateTime(), nullable=False),
        sa.ForeignKeyConstraint(['pet_id'], ['pets.id']),
        sa.ForeignKeyConstraint(['photo_id'], ['photos.id'], ondelete='SET NULL'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_pet_photo_embeddings_pet_id', 'pet_photo_embeddings', ['pet_id'])
    op.create_index('ix_pet_photo_embeddings_created_at', 'pet_photo_embeddings', ['created_at'])

    # IVFFlat 索引：lists 参数在 < 1000 条数据时几乎不起作用；实现时先建空索引，
    # 等线上数据量 > 500 行之后运维手动 REINDEX 并调 lists。
    op.execute(
        "CREATE INDEX ix_pet_photo_embeddings_cosine "
        "ON pet_photo_embeddings USING ivfflat (embedding vector_cosine_ops) "
        "WITH (lists = 50)"
    )


def downgrade() -> None:
    op.drop_index('ix_pet_photo_embeddings_cosine', table_name='pet_photo_embeddings')
    op.drop_index('ix_pet_photo_embeddings_created_at', table_name='pet_photo_embeddings')
    op.drop_index('ix_pet_photo_embeddings_pet_id', table_name='pet_photo_embeddings')
    op.drop_table('pet_photo_embeddings')
    op.execute("DROP TYPE IF EXISTS embeddingsource")
    # CREATE EXTENSION 不做 DROP，可能被其它未来 migration 使用
```

### 4.1 SQLite 测试兼容

测试栈用 SQLite（[backend/tests/conftest.py](../backend/tests/conftest.py)）。SQLite 没有 `vector` 类型也没有 ivfflat。两种处理：

**方案 A（推荐）**：在 [backend/tests/\_sqlite\_compat.py](../backend/tests/_sqlite_compat.py) 里把 `Vector` 映射为 `JSON`：

```python
from sqlalchemy.types import JSON
from pgvector.sqlalchemy import Vector

# SQLite fallback for vector type
@compiles(Vector, 'sqlite')
def _compile_vector_sqlite(type_, compiler, **kw):
    return compiler.visit_JSON(JSON(), **kw)
```

然后在 `services/pet_centroid.py` 里判断 `DATABASE_URL.startswith('sqlite')` 走 Python 端余弦相似度，否则走 pgvector `<=>` 运算符。

**方案 B**：测试里直接 mock `pet_centroid.classify`，不实际跑向量查询。

单元测试默认 A，集成测试（真 Postgres + pgvector）走 B 的反向——用 `@pytest.mark.pgvector` 标记，CI 里起真容器跑。

---

## 5. 后端：Service 层

### 5.1 `services/embedding.py`（DashScope 封装）

新建 [backend/app/services/embedding.py](../backend/app/services/embedding.py)：

```python
import base64
import io
import logging
from typing import Sequence

import httpx
from PIL import Image

from app.config import settings

logger = logging.getLogger(__name__)

_DASHSCOPE_EMBEDDING_URL = (
    "https://dashscope.aliyuncs.com/api/v1/services/embeddings/multimodal-embedding/multimodal-embedding"
)
_MAX_SIDE = 512


class EmbeddingUnavailableError(RuntimeError):
    """DashScope 暂不可用或配额不足。"""


async def embed_image(image_bytes: bytes) -> list[float]:
    """调 DashScope 多模态 embedding，返回 1024 维向量。

    image_bytes: 原图 JPEG/PNG/WEBP 都行；内部压缩到长边 512 再转 base64。
    """
    if not settings.DASHSCOPE_API_KEY:
        raise EmbeddingUnavailableError("DASHSCOPE_API_KEY 未配置")

    compressed = _compress(image_bytes)
    b64 = base64.b64encode(compressed).decode("ascii")

    payload = {
        "model": settings.DASHSCOPE_EMBEDDING_MODEL,
        "input": {"contents": [{"image": f"data:image/jpeg;base64,{b64}"}]},
    }
    headers = {
        "Authorization": f"Bearer {settings.DASHSCOPE_API_KEY}",
        "Content-Type": "application/json",
    }

    async with httpx.AsyncClient(timeout=10.0) as client:
        resp = await client.post(_DASHSCOPE_EMBEDDING_URL, json=payload, headers=headers)
    if resp.status_code >= 400:
        logger.warning("DashScope embedding failed: %s %s", resp.status_code, resp.text[:500])
        raise EmbeddingUnavailableError(f"HTTP {resp.status_code}")

    data = resp.json()
    try:
        vec = data["output"]["embeddings"][0]["embedding"]
    except (KeyError, IndexError) as e:
        raise EmbeddingUnavailableError(f"Bad response: {data}") from e

    if len(vec) != 1024:
        raise EmbeddingUnavailableError(
            f"Unexpected dim {len(vec)}, expected 1024. "
            f"Check DASHSCOPE_EMBEDDING_MODEL={settings.DASHSCOPE_EMBEDDING_MODEL}"
        )
    return vec


def _compress(image_bytes: bytes) -> bytes:
    im = Image.open(io.BytesIO(image_bytes))
    im = im.convert("RGB")
    w, h = im.size
    scale = _MAX_SIDE / max(w, h)
    if scale < 1:
        im = im.resize((int(w * scale), int(h * scale)), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, format="JPEG", quality=85)
    return buf.getvalue()
```

### 5.2 `services/pet_centroid.py`（向量库读写 + 判决）

新建 [backend/app/services/pet_centroid.py](../backend/app/services/pet_centroid.py)：

```python
import json
import logging
from dataclasses import dataclass

from redis.asyncio import Redis
from sqlalchemy import select, func
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.pet import Pet, PetMember, MemberRole
from app.models.pet_photo_embedding import PetPhotoEmbedding, EmbeddingSource
from app.services.pet import ROLE_LEVEL
from app.utils.time import utcnow

logger = logging.getLogger(__name__)

# 判决阈值（文档 §9 有调参表）
SIM_TOP1_MIN = 0.78
SIM_MARGIN_MIN = 0.05
CENTROID_CACHE_TTL = 300  # 秒


@dataclass(frozen=True)
class ClassifyCandidate:
    pet_id: int
    similarity: float


@dataclass(frozen=True)
class ClassifyResult:
    pet_id: int | None
    confidence: float | None  # 命中时 = Top-1 similarity，未命中时 None


async def list_editor_pets(db: AsyncSession, user_id: int) -> list[int]:
    """返回该用户 OWNER / EDITOR 的 pet_id 列表。VIEWER 的不参与候选。"""
    stmt = (
        select(PetMember.pet_id)
        .where(
            PetMember.user_id == user_id,
            PetMember.role.in_([MemberRole.OWNER, MemberRole.EDITOR]),
        )
    )
    rows = await db.execute(stmt)
    return [r[0] for r in rows.all()]


async def classify(
    db: AsyncSession,
    user_id: int,
    vector: list[float],
    *,
    redis: Redis | None = None,
) -> ClassifyResult:
    pet_ids = await list_editor_pets(db, user_id)
    if not pet_ids:
        return ClassifyResult(pet_id=None, confidence=None)

    # 直接在 DB 侧按 cosine distance 排序；pgvector 的 <=> 是 cosine distance，sim = 1 - dist
    stmt = (
        select(
            PetPhotoEmbedding.pet_id,
            (1 - PetPhotoEmbedding.embedding.cosine_distance(vector)).label("sim"),
        )
        .where(PetPhotoEmbedding.pet_id.in_(pet_ids))
        .order_by(PetPhotoEmbedding.embedding.cosine_distance(vector))
        .limit(20)
    )
    rows = (await db.execute(stmt)).all()
    if not rows:
        return ClassifyResult(pet_id=None, confidence=None)

    # 把同一 pet 多条 embedding 合并：取该 pet 的最大 sim
    best_by_pet: dict[int, float] = {}
    for pet_id, sim in rows:
        if pet_id not in best_by_pet or sim > best_by_pet[pet_id]:
            best_by_pet[pet_id] = float(sim)

    ranked = sorted(best_by_pet.items(), key=lambda x: -x[1])
    top1_pet, top1_sim = ranked[0]
    top2_sim = ranked[1][1] if len(ranked) > 1 else 0.0

    if top1_sim >= SIM_TOP1_MIN and (top1_sim - top2_sim) >= SIM_MARGIN_MIN:
        return ClassifyResult(pet_id=top1_pet, confidence=round(top1_sim, 3))
    return ClassifyResult(pet_id=None, confidence=None)


async def add_embedding(
    db: AsyncSession,
    *,
    pet_id: int,
    photo_id: int | None,
    vector: list[float],
    source: EmbeddingSource,
) -> None:
    row = PetPhotoEmbedding(
        pet_id=pet_id,
        photo_id=photo_id,
        embedding=vector,
        source=source,
        created_at=utcnow(),
    )
    db.add(row)
    await db.commit()
```

> `cosine_distance(...)` 是 `pgvector.sqlalchemy.Vector` 提供的辅助方法，等价于 `embedding <=> :v`。SQLite 环境下该方法不可用，单元测试用方案 A 走 JSON + Python 计算（文档 §4.1）。

---

## 6. 后端：API 层

### 6.1 `POST /api/v1/photos/classify`

新建 [backend/app/api/v1/classify.py](../backend/app/api/v1/classify.py)：

```python
import asyncio
import logging

from fastapi import APIRouter, Depends, File, UploadFile
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import get_db, get_current_user_id
from app.exceptions import AppException
from app.schemas.classify import ClassifyResponse, ClassifyResult
from app.services.embedding import embed_image, EmbeddingUnavailableError
from app.services.pet_centroid import classify as centroid_classify

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/photos", tags=["classify"])

_ALLOWED_MIME = {"image/jpeg", "image/png", "image/webp"}
_MAX_BYTES = 15 * 1024 * 1024
_MAX_FILES = 5


@router.post("/classify", response_model=ClassifyResponse)
async def classify_photos(
    files: list[UploadFile] = File(...),
    db: AsyncSession = Depends(get_db),
    user_id: int = Depends(get_current_user_id),
):
    if not files:
        raise AppException(400, "CLASSIFY_EMPTY", "至少提交一张照片")
    if len(files) > _MAX_FILES:
        raise AppException(400, "CLASSIFY_TOO_MANY", f"最多 {_MAX_FILES} 张")

    # 读取 + 校验（保持与 /pets/{id}/photos 对称）
    payloads: list[tuple[int, bytes]] = []
    for idx, f in enumerate(files):
        if f.content_type not in _ALLOWED_MIME:
            raise AppException(400, "CLASSIFY_BAD_MIME", f"第 {idx+1} 张格式不支持")
        data = await f.read()
        if not data:
            raise AppException(400, "CLASSIFY_EMPTY_FILE", f"第 {idx+1} 张为空")
        if len(data) > _MAX_BYTES:
            raise AppException(400, "CLASSIFY_TOO_LARGE", f"第 {idx+1} 张超过 15MB")
        payloads.append((idx, data))

    async def _one(idx: int, data: bytes) -> ClassifyResult:
        try:
            vec = await embed_image(data)
        except EmbeddingUnavailableError:
            # 上游不可用按「未识别」返回，不抛 5xx，避免阻塞整条记录链路
            return ClassifyResult(file_index=idx, pet_id=None, confidence=None)
        result = await centroid_classify(db, user_id, vec)
        return ClassifyResult(file_index=idx, pet_id=result.pet_id, confidence=result.confidence)

    results = await asyncio.gather(*[_one(i, d) for i, d in payloads])
    return ClassifyResponse(results=list(results))
```

### 6.2 Schemas

新建 [backend/app/schemas/classify.py](../backend/app/schemas/classify.py)：

```python
from pydantic import BaseModel


class ClassifyResult(BaseModel):
    file_index: int
    pet_id: int | None
    confidence: float | None  # 0-1


class ClassifyResponse(BaseModel):
    results: list[ClassifyResult]
```

### 6.3 路由注册

[backend/app/api/v1/router.py](../backend/app/api/v1/router.py)：

```python
from app.api.v1 import auth, pets, photos, health, share, voice, classify
api_v1_router.include_router(classify.router)
```

### 6.4 响应示例

**请求**：`multipart/form-data`，`files[]` = 2 张照片（一张咪咪、一张橘子）

**响应 200**：

```json
{
  "results": [
    { "file_index": 0, "pet_id": 3, "confidence": 0.823 },
    { "file_index": 1, "pet_id": 7, "confidence": 0.794 }
  ]
}
```

**未识别的情况（档案池空 / 低置信 / 上游挂）**：

```json
{
  "results": [
    { "file_index": 0, "pet_id": null, "confidence": null }
  ]
}
```

**错误响应**：只在参数校验层抛，模型层全部软失败：

| HTTP | code | 场景 |
|---|---|---|
| 400 | `CLASSIFY_EMPTY` | `files` 空 |
| 400 | `CLASSIFY_TOO_MANY` | > 5 张 |
| 400 | `CLASSIFY_BAD_MIME` | 非 jpg/png/webp |
| 400 | `CLASSIFY_EMPTY_FILE` | 单张空 |
| 400 | `CLASSIFY_TOO_LARGE` | > 15MB |

---

## 7. 后端：上传回流（不改 `/pets/{pet_id}/photos` 入参）

### 7.1 旧接口**不改签名**，只加 2 个可选字段

[backend/app/api/v1/photos.py](../backend/app/api/v1/photos.py) 的 `upload_photos`：新增可选 Form 字段 `classify_source: list[str] = Form(default_factory=list)`。合法值：`"auto"`（默认，等价 `USER_UPLOADED`）、`"corrected"`（等价 `USER_CORRECTED`，用户改过 Chip）。
未传时全部按 `"auto"`。

### 7.2 上传成功后异步回流

`photos.py` 里 `_process_one` 成功分支最后（已经拿到 `photo_id` 与原始 `file_data`）追加：

```python
from app.services.embedding import embed_image, EmbeddingUnavailableError
from app.services.pet_centroid import add_embedding
from app.models.pet_photo_embedding import EmbeddingSource

async def _enqueue_embedding(pet_id: int, photo_id: int, data: bytes, source: EmbeddingSource):
    try:
        vec = await embed_image(data)
        await add_embedding(db, pet_id=pet_id, photo_id=photo_id, vector=vec, source=source)
    except EmbeddingUnavailableError as e:
        logger.warning("embedding backfill skipped photo=%s reason=%s", photo_id, e)

# 在 _process_one 的 success 分支结尾：
src = EmbeddingSource.USER_CORRECTED if classify_source_for_idx == "corrected" else EmbeddingSource.USER_UPLOADED
background_tasks.add_task(_enqueue_embedding, pet_id, photo.id, file_data, src)
```

- 用 FastAPI 的 `BackgroundTasks` 异步化，**不能阻塞上传响应**——否则用户会觉得"上传变慢了"。
- DashScope 出问题不影响主链路成功；下次该照片再被分类时也不会命中它，但不影响功能。
- 如果未来要更稳，可以换成写 Redis Stream，由独立 worker 消费（本步骤先走 BackgroundTasks，Step 4 之外的性能优化再说）。

---

## 8. Bootstrap / 兜底流程（关键）

这是整个系统最容易翻车的地方。必须独立成章详细说明，agent 实现时按此行事，不要自己发挥。

### 8.1 场景 A：新建档案、池里 0 条 embedding

- classify 返回 `{pet_id: null}`，前端 Chip 显示"选择宠物"
- 用户手点宠物 → 提交时把 `classify_source[该 idx] = "corrected"`，后端回流为 `USER_CORRECTED`
- 下次用户再选同一只宠物的其它照片，该宠物已有 1 条 `USER_CORRECTED` embedding，sim 一般 > 0.9 → 命中

### 8.2 场景 B：多只宠物，档案里都有一些 embedding 但分布不均

- Top-1 与 Top-2 都 > 0.7 但差 < 0.05 → 视为低置信 → `pet_id: null` → 让用户手选
- 命中阈值 `SIM_TOP1_MIN = 0.78`、`SIM_MARGIN_MIN = 0.05` 为起始值。上线后看金标集（§10）命中率回测调整。

### 8.3 场景 C：用户修正自动识别结果

- 用户把 Chip 从"咪咪"改成"橘子"
- 提交时该 idx 的 `classify_source = "corrected"`；后端回流写 `USER_CORRECTED` 到**橘子**的池
- **不从咪咪池里删任何东西**（不做在线学习，避免误删）；只记录反例，等未来有足够数据再考虑降权或训练用户专属分类器
- 为便于未来的模型迭代，log 一条结构化日志：`{event: "classify_corrected", from_pet: 3, to_pet: 7, photo_id: X, top1_sim: 0.81}`

### 8.4 场景 D：上游 DashScope 不可用

- classify 接口：全部返回 `pet_id: null`，前端正常让用户选
- 上传回流：log warning，继续落库成功
- 不对用户做任何感知（不弹"识别失败"提示——用户只关心"Chip 是否正确"，不关心模型是否挂）

### 8.5 场景 E：候选池过大（用户拥有 20+ 只宠物）

- `services/pet_centroid.classify` 里用 `ORDER BY ... LIMIT 20` 限制；即便每只宠物 100 张 embedding，也只会取 Top-20 行进来合并
- Redis 缓存：key `pet_centroid:{user_id}`，值 `{pet_id_list, mtime}`；用户的宠物列表 5 分钟内不会变这个前提是安全的。超出缓存期 / 列表变更事件后失效即可

---

## 9. 前端改造

### 9.1 依赖（无新增三方库）

不新增 Flutter 包。`PetChipDropdown` 用自带 Material `PopupMenuButton` + `Chip`。

### 9.2 新组件 `PetChipDropdown`

新建 [frontend/lib/widgets/pet_chip_dropdown.dart](../frontend/lib/widgets/pet_chip_dropdown.dart)：

```dart
import 'package:flutter/material.dart';
import '../config/theme.dart';
import '../models/pet.dart';

/// Compact chip showing the classify result with a tap-to-change affordance.
///
/// States:
///   - [isRecognizing] true: spinner + 「识别中」, non-interactive
///   - [selected] != null: 头像 + 宠物名 + 下拉箭头
///   - [selected] == null: 灰色「选择宠物」+ 下拉箭头
class PetChipDropdown extends StatelessWidget {
  final List<Pet> pets;          // 候选（上层过滤掉 viewer-only 的）
  final Pet? selected;
  final bool isRecognizing;
  final bool wasAutoAssigned;    // true = 模型给的，false = 用户手点过
  final ValueChanged<Pet> onChanged;

  const PetChipDropdown({
    super.key,
    required this.pets,
    required this.selected,
    required this.isRecognizing,
    required this.wasAutoAssigned,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (isRecognizing) {
      return _wrap(
        child: Row(mainAxisSize: MainAxisSize.min, children: const [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
          SizedBox(width: 6),
          Text('识别中', style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        ]),
      );
    }

    return PopupMenuButton<int>(
      onSelected: (id) => onChanged(pets.firstWhere((p) => p.id == id)),
      itemBuilder: (ctx) => pets
          .map((p) => PopupMenuItem(
                value: p.id,
                child: Row(children: [
                  _avatar(p, 22),
                  const SizedBox(width: 8),
                  Text(p.name),
                  if (selected?.id == p.id)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.check, size: 16, color: AppTheme.primaryColor),
                    ),
                ]),
              ))
          .toList(),
      child: _wrap(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (selected != null) ...[
            _avatar(selected!, 18),
            const SizedBox(width: 6),
            Text(selected!.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500)),
          ] else
            const Text('选择宠物', style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
          const Icon(Icons.arrow_drop_down, size: 18, color: AppTheme.textSecondary),
        ]),
      ),
    );
  }

  Widget _wrap({required Widget child}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: wasAutoAssigned
              ? AppTheme.primaryColor.withValues(alpha: 0.08)
              : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(16),
        ),
        child: child,
      );

  Widget _avatar(Pet p, double size) {
    // 复用 PetSelector._buildPetAvatar 的样式，抽成 util 或就地实现
    // ...
  }
}
```

### 9.3 新服务 `ClassifyService`

新建 [frontend/lib/services/classify_service.dart](../frontend/lib/services/classify_service.dart)：

```dart
import 'dart:io';
import 'package:dio/dio.dart';
import 'api_client.dart';

class ClassifyResult {
  final int fileIndex;
  final int? petId;
  final double? confidence;
  const ClassifyResult({required this.fileIndex, this.petId, this.confidence});
  factory ClassifyResult.fromJson(Map<String, dynamic> j) => ClassifyResult(
        fileIndex: j['file_index'] as int,
        petId: j['pet_id'] as int?,
        confidence: (j['confidence'] as num?)?.toDouble(),
      );
}

class ClassifyService {
  final Dio _dio = ApiClient().dio;

  /// Classify up to 5 files in one shot. Server runs embeddings in parallel.
  Future<List<ClassifyResult>> classify(List<File> files) async {
    final fd = FormData();
    for (final f in files) {
      fd.files.add(MapEntry(
        'files',
        MultipartFile.fromFileSync(f.path, filename: f.path.split('/').last),
      ));
    }
    final resp = await _dio.post(
      '/photos/classify',
      data: fd,
      options: Options(sendTimeout: const Duration(seconds: 30), receiveTimeout: const Duration(seconds: 30)),
    );
    final list = (resp.data['results'] as List).cast<Map<String, dynamic>>();
    return list.map(ClassifyResult.fromJson).toList();
  }
}
```

### 9.4 记录页 `record_screen.dart` 改造

目标最终交互（对比当前代码 [record_screen.dart](../frontend/lib/screens/record/record_screen.dart)）：

**去掉**：
- `AppBar` 里的 `PetSelector`（行 58-74）
- 依赖 `selectedPet` 判定"要不要展示空态"的逻辑，改为用 `petListProvider` 是否 empty

**新增字段**到 `_RecordScreenState`：

```dart
final List<int?> _assignedPetIds = [];          // 每张照片当前 chip 的 pet_id
final List<bool> _wasAutoAssigned = [];         // 识别给的还是用户手点过
final List<bool> _isRecognizing = [];           // 当前是否在跑 classify
```

三个数组与 `_selectedFiles` / `_photoDates` / `_pendingTokens` 一一对应；`_removePhoto` / `_pickDateForPhoto` / `_handleUploadResult` 同步删/留对应下标。

**照片卡片布局改造**（`_buildPhotoCard`）：

原代码最后一行的"日期 picker row"（Row 里只有日历图标 + 日期 + 箭头）改成：

```dart
Padding(
  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
  child: Row(
    children: [
      GestureDetector(
        onTap: _isUploading ? null : () => _pickDateForPhoto(index),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.calendar_today, size: 18, color: AppTheme.textSecondary),
            const SizedBox(width: 8),
            Text(_dateFormat.format(date), style: const TextStyle(fontSize: 15)),
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 18, color: Colors.grey.shade400),
          ],
        ),
      ),
      const Spacer(),
      PetChipDropdown(
        pets: _editableCandidatePets,
        selected: _assignedPetIds[index] == null
            ? null
            : _editableCandidatePets.firstWhere((p) => p.id == _assignedPetIds[index]),
        isRecognizing: _isRecognizing[index],
        wasAutoAssigned: _wasAutoAssigned[index],
        onChanged: (pet) => setState(() {
          _assignedPetIds[index] = pet.id;
          _wasAutoAssigned[index] = false;  // 用户动过
        }),
      ),
    ],
  ),
),
```

`_editableCandidatePets` getter：

```dart
List<Pet> get _editableCandidatePets =>
    (ref.read(petListProvider).valueOrNull?.pets ?? const <Pet>[])
        .where((p) => p.role == PetRole.owner || p.role == PetRole.editor)
        .toList();
```

**选完照片并发调 classify**（改 `_pickFromGallery` / `_takePhoto` 的尾部）：

```dart
// 先把本地 cat/dog 过滤完的 `files` 加入 state、chip 设为「识别中」
final baseIdx = _selectedFiles.length;
setState(() {
  _selectedFiles.addAll(files);
  _photoDates.addAll(dates);
  _pendingTokens.addAll(tokens);
  _assignedPetIds.addAll(List.filled(files.length, null));
  _wasAutoAssigned.addAll(List.filled(files.length, true));
  _isRecognizing.addAll(List.filled(files.length, true));
});

// 异步调 classify，回来填 chip
unawaited(() async {
  try {
    final results = await ref.read(_classifyServiceProvider).classify(files);
    if (!mounted) return;
    setState(() {
      for (final r in results) {
        final absIdx = baseIdx + r.fileIndex;
        if (absIdx >= _assignedPetIds.length) continue;
        _assignedPetIds[absIdx] = r.petId;
        _wasAutoAssigned[absIdx] = r.petId != null;
        _isRecognizing[absIdx] = false;
      }
    });
  } catch (_) {
    // classify 整体失败：全部标未识别让用户手选
    if (!mounted) return;
    setState(() {
      for (int i = baseIdx; i < _selectedFiles.length; i++) {
        _isRecognizing[i] = false;
      }
    });
  }
}());
```

**提交改造**（`_submit`）：

```dart
Future<void> _submit() async {
  if (_selectedFiles.isEmpty) return;

  // 校验：每张都必须有 pet_id，没有就 toast 提示用户
  final missing = <int>[];
  for (int i = 0; i < _assignedPetIds.length; i++) {
    if (_assignedPetIds[i] == null) missing.add(i + 1);
  }
  if (missing.isNotEmpty) {
    _showSnack('第 ${missing.join("、")} 张还没选择宠物');
    return;
  }

  // 按 pet_id 分组
  final groups = <int, List<int>>{};
  for (int i = 0; i < _selectedFiles.length; i++) {
    groups.putIfAbsent(_assignedPetIds[i]!, () => []).add(i);
  }

  setState(() => _isUploading = true);
  _showUploadDialog();

  final service = ref.read(_photoServiceProvider);
  int totalOk = 0;
  int totalFail = 0;
  final Map<int, String> allFailures = {};
  final Set<int> allSuccesses = {};

  try {
    for (final entry in groups.entries) {
      final petId = entry.key;
      final indices = entry.value;
      final files = [for (final i in indices) _selectedFiles[i]];
      final dates = [for (final i in indices) _dateFormat.format(_photoDates[i])];
      final sources = [for (final i in indices) _wasAutoAssigned[i] ? 'auto' : 'corrected'];

      final resp = await service.uploadPhotos(
        petId: petId,
        files: files,
        takenAtDates: dates,
        classifySources: sources,   // ← PhotoService 新参数
        onSendProgress: (sent, total) { /* ... */ },
      );

      for (final s in resp.successes) {
        allSuccesses.add(indices[s.index]);
      }
      for (final f in resp.failures) {
        allFailures[indices[f.index]] = f.message;
      }
      totalOk += resp.successCount;
      totalFail += resp.failureCount;
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    // 复用现有 _bindUploadedToCache + _handleUploadResult 的"基于 indices"的部分
    // ...（把现有按单批的处理改成按 absolute index 处理）
  } catch (e) {
    // ...
  } finally {
    if (mounted) setState(() => _isUploading = false);
  }
}
```

`PhotoService.uploadPhotos` 新增 `List<String>? classifySources` 参数，追加到 FormData：

```dart
if (classifySources != null) {
  for (final s in classifySources) {
    formData.fields.add(MapEntry('classify_source', s));
  }
}
```

### 9.5 空态 / 无宠物档案

现在记录页空态文案（"请先创建宠物档案"）保留。**新增**一种情况：用户只拥有 VIEWER 角色的档案（不能上传任何照片）——此时 `_editableCandidatePets` 为空，记录页展示新文案"当前没有可编辑的宠物档案"。

---

## 10. 成本 / 延迟控制

- **Embedding 模型**：`multimodal-embedding-v1`，1024 维。当前 DashScope 挂牌价 ≈ ¥0.0007/张输入（以官网为准）。
- **单次 classify 成本**：≤ ¥0.001（5 张并发总计 < ¥0.005）。
- **单次 classify 延迟**（99 分位，5 张并发）：
  - 压缩 50ms × 5 = 250ms（在服务端 `asyncio.to_thread`）
  - DashScope 往返 400ms（上海 region）
  - pgvector 查询 10ms
  - 合计 ≈ 600-700ms
- **上传回流**：与响应解耦，用户感知为 0。
- **Redis 缓存**：
  - key: `pet_centroid:list:{user_id}` → editor pet_id 集合，TTL 300s
  - key: `classify:req_dedup:{user_id}:{sha1(file)}` → classify 结果，TTL 60s（同一张图 60s 内重复选不再打钱）

---

## 11. 测试计划

### 11.1 单元

- `services/embedding._compress`：1080p 输入 → 长边 512；极小图不放大；非 RGB 模式转 RGB
- `services/embedding.embed_image`：用 `httpx.MockTransport` 桩，断言 POST body / headers；响应 `embeddings[0].embedding` 被正确解析；错 shape / 非 200 抛 `EmbeddingUnavailableError`
- `services/pet_centroid.classify`：
  - 空池 → `(null, null)`
  - 只有一只宠物且 sim=0.9 → 命中（margin 规则在单行时视为 `top2_sim=0`）
  - 两只宠物 sim=0.85 / 0.82 → margin=0.03 < 0.05 → 未命中
  - 两只宠物 sim=0.85 / 0.75 → margin=0.10 → 命中 top1
- `services/pet_centroid.list_editor_pets`：VIEWER 不出现在候选池
- `add_embedding`：写入 + 查询往返一致

### 11.2 API

[backend/tests/api/test_classify.py](../backend/tests/api/test_classify.py)（新建）：

- `test_classify_empty_files_rejected` → 400 `CLASSIFY_EMPTY`
- `test_classify_too_many_rejected` → 400 `CLASSIFY_TOO_MANY`
- `test_classify_bad_mime_rejected` → 400 `CLASSIFY_BAD_MIME`
- `test_classify_embedding_unavailable_returns_null`（mock `embed_image` 抛错 → 200 results 全 null）
- `test_classify_hits_top1`（注入 2 只宠物的 embedding，传一张和其中一只最接近的 → 200 命中）
- `test_classify_low_margin_returns_null`（注入 2 条几乎相同的 sim → 未命中）
- `test_classify_viewer_pet_excluded`（候选池不含 VIEWER）
- `test_upload_with_corrected_source_marks_embedding`（调 `/pets/{id}/photos` 时传 `classify_source=corrected` → 回流 embedding 的 source=USER_CORRECTED）
- `test_upload_with_auto_source_default`

### 11.3 端到端金标集

`backend/tests/fixtures/classify/`：

- `cat_mimi/1..5.jpg`（5 张同一只橘猫）
- `cat_juzi/1..5.jpg`（5 张不同橘猫，用于考验分辨力）
- `dog_wangcai/1..5.jpg`

脚本 `tests/integration/test_classify_e2e.py`（默认 `@pytest.mark.dashscope_live` skip，CI 手动跑）：

- 每组前 3 张作为 bootstrap 入池（`USER_CORRECTED`），后 2 张跑 classify
- 断言命中率 ≥ 90%、跨组错认率 ≤ 5%
- 同种类猫（两只都是橘猫）跑一次，断言 margin 规则正确拒绝

### 11.4 前端 Widget 测试

[frontend/test/widgets/pet_chip_dropdown_test.dart](../frontend/test/widgets/pet_chip_dropdown_test.dart)：

- isRecognizing 时展示 spinner + 「识别中」，点击不触发 onChanged
- selected=null 时展示「选择宠物」；点开 popup 选一项后回调 onChanged
- wasAutoAssigned=true 时背景色为主色浅色；false 时为灰色

[frontend/test/screens/record_screen_test.dart](../frontend/test/screens/record_screen_test.dart)：

- 选 2 张不同宠物 → 模拟 classify 返回 `[{0, petA}, {1, petB}]` → chip 正确填入
- 点「记录完成」→ 断言 `PhotoService.uploadPhotos` 被分别以 petA / petB 调两次
- 有一张未识别（null）→ 点提交 → toast "第 X 张还没选择宠物"

---

## 12. 权限与安全

- `/photos/classify` 要登录；候选池只含 `OWNER / EDITOR` 的宠物——即便 LLM/模型攻击能诱导返回某个 `pet_id`，也只可能命中用户自己能写的档案，无法越权"识别到别人家的宠物"。
- 上传仍走 `services.photos.upload_photos`（EDITOR 及以上），classify 结果只是建议；真正的写入门槛在上传接口（Step 1 已有）。
- `.env` 新增 / 复用：

| 键名 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `DASHSCOPE_API_KEY` | 是 | — | 与 [phase2-step2](phase2-step2-voice-intake.md) 共用同一 key |
| `DASHSCOPE_EMBEDDING_MODEL` | 否 | `multimodal-embedding-v1` | 输出 1024 维 |
| `CLASSIFY_SIM_TOP1_MIN` | 否 | `0.78` | 命中阈值 |
| `CLASSIFY_SIM_MARGIN_MIN` | 否 | `0.05` | Top-1 与 Top-2 最小差 |
| `CLASSIFY_CACHE_TTL_SECONDS` | 否 | `300` | pet 列表缓存 |

- DashScope 响应里**不要**落 raw JSON 到数据库（不像 Step 2 的 LLM log 需要回归），只存最终向量即可；降合规风险、省空间。

---

## 13. 落地步骤（推荐顺序）

1. **基础设施**：`docker-compose.yml` 换 pgvector 镜像 → 本地 `docker compose down -v && up -d` → 手动 `psql -c 'CREATE EXTENSION vector'` 验证镜像工作 → 把命令改到 alembic。
2. **数据模型 + 迁移**：新建 `PetPhotoEmbedding` 模型 + alembic → `alembic upgrade head` 能通过 → 跑既有 test（SQLite 下用兼容 shim）不炸。
3. **Service 层**：`embedding.py` + `pet_centroid.py`，用 pytest + mock 跑通单测。
4. **Classify API**：新建 `classify.py` + schema + 单测；用 Swagger UI（`/docs`）手动打一发，给 fake 向量入池验证命中。
5. **上传回流**：改 `photos.py` 加 `classify_source` Form 字段 + BackgroundTasks；补 2 个 API 测试。
6. **前端组件 / 服务**：`PetChipDropdown` + `ClassifyService` + widget 测试。
7. **记录页改造**：改 `record_screen.dart`；真机跑一下"选 3 张不同宠物 → 看 chip 自动填 → 改 chip → 提交 → 时间线看分散到 3 只宠物"。
8. **端到端金标回归**：准备 fixture 照片 → 跑 `@pytest.mark.dashscope_live` 集成测试。
9. **灰度开关**：`.env` 加 `FEATURE_AUTO_ASSIGN=true`；默认 true，极端情况下运维可关（接口返回空 results，前端退化到"全部未识别，用户手选"）。
10. **commit**：按 `backend/infra/frontend` 三提交，便于 revert。

---

## 14. Out of Scope（明确不做）

> 实现时不要扩散到以下功能。如果用户在 issue 里提到，请明确驳回。

- **在线增量学习**：用户修正的反例目前只 log，不更新模型权重、不降权历史 embedding。
- **多用户家庭共享 centroid**：pet 是 user 维度的候选，不跨 user 合并。
- **人脸 / 生物识别**：不做五官定位、不做花色分割。
- **视频 / Live Photo**：只处理静态图。
- **宠物档案 avatar 自动入池**（`EmbeddingSource.PET_AVATAR`）：枚举保留，本步骤**不实现**自动写入；未来做档案引导流程时再说。
- **跨宠物原子上传接口**：本步骤仍用前端按 pet_id 分组调旧接口，不引入 `/photos/bulk` 这类原子版本。

---

## 15. 主要取舍

- **不用 LLM 做识别**：VLM（qwen-vl）能"看图说话"但 500-800ms × 每张 + 单张 ¥0.02，5 张就是 ¥0.1；embedding 方案单张 0.001 元、一次 600ms 总延迟，对"识别宠物归属"这种受限分类任务性价比压倒性胜出。
- **Top-1 + margin 双阈值**：纯 Top-1 阈值在"两只长得像的橘猫"场景会硬切错；加 margin 规则后"拿不准就让用户选"，用户体验比"自信地选错"好很多。
- **BackgroundTasks 回流 vs Stream worker**：本步骤走前者，简单、够用；规模到每日 5 万张以后再加独立消费者。
- **不在创建宠物时强制头像**：用户反感强制流程；靠"首次上传时用户手选的照片"作 bootstrap，冷启动 1-2 次就足够用，不牺牲易用性换模型冷启动。
- **SQLite 测试走 JSON shim**：避免 CI 必须起 Postgres + pgvector 容器；真实向量行为用 `@pytest.mark.pgvector` 单独跑。

---

## 附录 A：响应示例

**`POST /api/v1/photos/classify`** with 3 files → `200`

```json
{
  "results": [
    { "file_index": 0, "pet_id": 3, "confidence": 0.823 },
    { "file_index": 1, "pet_id": null, "confidence": null },
    { "file_index": 2, "pet_id": 7, "confidence": 0.794 }
  ]
}
```

**错误**：6 个文件 → `400`

```json
{
  "code": "CLASSIFY_TOO_MANY",
  "message": "最多 5 张",
  "details": null
}
```

## 附录 B：调优参数 Runbook

上线两周后如果命中率偏低：

1. 看 log 里 `top1_sim` 分布——如果 80% 的 hit 都在 0.7-0.78 之间，说明阈值过严，调低到 0.72
2. 看 `classify_corrected` 事件——如果同一只宠物被频繁误认为另一只，看两只宠物的 embedding 分布，必要时手动在管理后台打标几条 `PET_AVATAR` 样本（未来做的后台工具）
3. 线上 p99 延迟 > 1.5s：关 ivfflat 索引用 brute force（数据量 < 5000 时反而更快）
