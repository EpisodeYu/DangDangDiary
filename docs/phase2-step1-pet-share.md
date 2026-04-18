# Phase 2 - Step 1: 宠物档案分享

## 项目背景

「当当日记」Phase 1 已经在 `pets` + `pet_members` 表上预埋了"宠物档案 = 多用户成员"的数据结构（见 [backend/app/models/pet.py](../backend/app/models/pet.py) 中的 `Pet`、`PetMember`、`MemberRole`），但实际只支持单一 `OWNER` 角色，没有任何邀请、共享和权限管理入口。Phase 2 第一步把"宠物档案分享"做完整，并把权限模型从「OWNER / MEMBER」升级到「OWNER / EDITOR / VIEWER」三级。

**前置依赖**：Step 3（宠物档案 CRUD）+ Step 8（鲁棒性收尾）已完成，下面所有路径与符号均以 main 分支当前实现为准。

---

## 本步骤目标

1. 后端：在 `MemberRole` 枚举中删除历史 `MEMBER`、新增 `EDITOR` 与 `VIEWER`，并通过 alembic 把数据库里的旧 `MEMBER` 行迁为 `VIEWER`。
2. 后端：新增 `pet_share_codes` 表，落地 8 位、24 小时有效、可审计的分享码。
3. 后端：新增「生成 / 查询 / 撤销分享码」「兑换分享码」「列出/升降/移除已分享成员」7 个 API。
4. 后端：把 `update_pet` / `upload_avatar` / 所有照片写接口 / 所有健康写接口的权限从「OWNER-only」放宽到「至少 EDITOR」；`delete_pet` / 分享相关接口仍 OWNER-only。
5. 前端：在「我的 → 宠物档案管理」下方新增「宠物档案分享」入口，进入后是宠物列表 → 宠物分享详情页（上半生成码、下半成员管理）。
6. 前端：在「创建宠物档案」页"保存"按钮下方新增「通过分享码添加档案」按钮 + 输入弹窗。
7. 前端：在「宠物档案管理」列表卡片右上角展示文字角标「拥有 / 编辑 / 查看」。

---

## 0. 与 Phase 1 既有约定的关系

- **全局规则 §8 共享档案权限**（见 [docs/00-global-rules.md](00-global-rules.md)）：原文是 `member` 默认可以新增、编辑、删除普通记录，但不能删宠物本身。本步把 `MEMBER` 拆为 `EDITOR`（满足原文行为）和 `VIEWER`（只读）；并在本文档「权限矩阵」一节作为该规则在 Phase 2 的具体落地。
- **API 约定**：沿用 [docs/00-global-rules.md](00-global-rules.md) §4：`snake_case`；列表用 `pets` / `members` / `share_codes` 之类语义 key；删除返回 `204`；错误返回 `{code, message, details}`。
- **存储**：分享码走 PostgreSQL，不依赖 Redis（符合「可审计」选型）。
- **`Pet.invite_code` 字段**：Phase 1 残留的 6 位静态 `invite_code` 列继续保留以避免破坏数据库与已发布 API；本步**不再消费它**，仅在响应里继续按 OWNER 可见返回，文档里标注为 *deprecated, planned for removal in a later step*。

---

## 1. 数据模型变更

### 1.1 `MemberRole` 枚举升级

文件：[backend/app/models/pet.py](../backend/app/models/pet.py)

```python
class MemberRole(str, enum.Enum):
    OWNER = "owner"
    EDITOR = "editor"
    VIEWER = "viewer"
```

- 删除原 `MEMBER = "member"`。
- 任何之前 `select(... MemberRole.MEMBER)` 的调用点必须替换；现网代码里实际只在 [backend/tests/api/test_pets.py](../backend/tests/api/test_pets.py)（`test_member_can_read_but_not_write` 断言 `my_role == "member"`）使用，需在测试改写时一起更新（见第 8 节）。

### 1.2 新增 `PetShareCode` 模型

同文件追加：

```python
class PetShareCode(Base):
    __tablename__ = "pet_share_codes"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    pet_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("pets.id"), nullable=False, index=True)
    code: Mapped[str] = mapped_column(String(16), unique=True, nullable=False)
    created_by: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    used_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    used_by_user_id: Mapped[int | None] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=True)
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow)
```

设计要点：
- `code` 长度按需求是 8 位字符；`String(16)` 给未来扩展留余量。
- "活码" = `revoked_at IS NULL AND used_at IS NULL AND expires_at > now()`。
- 每个宠物**同时最多一个活码**：生成新码前把同 pet 之前所有活码 `revoked_at = utcnow()`（见 §3.2）。
- 兑换是单次：成功后写 `used_at` + `used_by_user_id`；后续再次输入提示"分享码已被使用"。

### 1.3 模型注册

文件：[backend/app/models/__init__.py](../backend/app/models/__init__.py)

```python
from app.models.pet import Pet, PetMember, PetShareCode, PetType, MemberRole
```

并补到 `__all__` 列表里，否则 alembic autogenerate 不会发现新表。

文件：[backend/alembic/env.py](../backend/alembic/env.py)
导入新模型 `PetShareCode`，使 `Base.metadata` 能见到它。

---

## 2. Alembic 迁移

新建 `backend/alembic/versions/d4e5f6a7b8c9_phase2_pet_share.py`，`down_revision = 'c3d4e5f6a7b8'`（即 step8 的 `c3d4e5f6a7b8_step8_compound_indexes.py`）。

### 2.1 升级（`upgrade()`）

按以下顺序执行（一定要在同一事务内完成）：

1. **新建表**：
   ```python
   op.create_table(
       'pet_share_codes',
       sa.Column('id', sa.BigInteger(), autoincrement=True, nullable=False),
       sa.Column('pet_id', sa.BigInteger(), nullable=False),
       sa.Column('code', sa.String(length=16), nullable=False),
       sa.Column('created_by', sa.BigInteger(), nullable=False),
       sa.Column('expires_at', sa.DateTime(), nullable=False),
       sa.Column('used_at', sa.DateTime(), nullable=True),
       sa.Column('used_by_user_id', sa.BigInteger(), nullable=True),
       sa.Column('revoked_at', sa.DateTime(), nullable=True),
       sa.Column('created_at', sa.DateTime(), nullable=False),
       sa.ForeignKeyConstraint(['pet_id'], ['pets.id']),
       sa.ForeignKeyConstraint(['created_by'], ['users.id']),
       sa.ForeignKeyConstraint(['used_by_user_id'], ['users.id']),
       sa.PrimaryKeyConstraint('id'),
       sa.UniqueConstraint('code', name='uq_pet_share_codes_code'),
   )
   op.create_index('ix_pet_share_codes_pet_id', 'pet_share_codes', ['pet_id'])
   op.create_index(
       'ix_pet_share_codes_pet_active',
       'pet_share_codes', ['pet_id', 'revoked_at', 'used_at', 'expires_at'],
   )
   ```

2. **重建 `memberrole` enum**（Postgres 里 `DROP VALUE` 不被支持，必须创建新类型再切换）：

   ```python
   op.execute("ALTER TYPE memberrole ADD VALUE IF NOT EXISTS 'EDITOR'")
   op.execute("ALTER TYPE memberrole ADD VALUE IF NOT EXISTS 'VIEWER'")
   op.execute("UPDATE pet_members SET role = 'VIEWER' WHERE role = 'MEMBER'")

   op.execute("ALTER TYPE memberrole RENAME TO memberrole_old")
   op.execute("CREATE TYPE memberrole AS ENUM ('OWNER', 'EDITOR', 'VIEWER')")
   op.execute(
       "ALTER TABLE pet_members "
       "ALTER COLUMN role TYPE memberrole USING role::text::memberrole"
   )
   op.execute("DROP TYPE memberrole_old")
   ```

   注意：`ALTER TYPE ... ADD VALUE` 在 Postgres ≥ 12 必须在隔离事务里执行。Alembic 4.x 默认每个 migration 一个事务，遇到这个会报错；解决方案是在该 migration 顶部加 `op.get_bind().execute(sa.text("COMMIT"))` 提前提交，或者直接拆出一个独立小迁移先 `ADD VALUE` 再正式重建。**实现时建议**：跳过 `ADD VALUE` 那两行，直接走 RENAME → CREATE → ALTER COLUMN → DROP 路径，整个过程在单事务里完成、不需要先 ADD（USING 的 cast 会把字符串值映射进新枚举）；`UPDATE pet_members SET role = 'VIEWER' WHERE role = 'MEMBER'` 必须放在 RENAME 之前（旧类型仍接受 'MEMBER'）。

### 2.2 降级（`downgrade()`）

按反向顺序：

```python
op.execute("ALTER TYPE memberrole RENAME TO memberrole_new")
op.execute("CREATE TYPE memberrole AS ENUM ('OWNER', 'MEMBER')")
op.execute("UPDATE pet_members SET role = 'MEMBER' WHERE role IN ('EDITOR', 'VIEWER')")
op.execute(
    "ALTER TABLE pet_members "
    "ALTER COLUMN role TYPE memberrole USING role::text::memberrole"
)
op.execute("DROP TYPE memberrole_new")
op.drop_index('ix_pet_share_codes_pet_active', table_name='pet_share_codes')
op.drop_index('ix_pet_share_codes_pet_id', table_name='pet_share_codes')
op.drop_table('pet_share_codes')
```

### 2.3 SQLite 测试兼容

测试栈用 SQLite + `_sqlite_compat.py`（[backend/tests/_sqlite_compat.py](../backend/tests/_sqlite_compat.py)，参考 [backend/tests/conftest.py](../backend/tests/conftest.py) 的使用方式）。SQLite 没有 ENUM 概念，`Base.metadata.create_all` 会把 enum 当成 VARCHAR + check constraint，所以测试侧不会受 enum 重建影响；`PetShareCode` 表在 SQLite 下也能直接 `create_all`。无需额外打补丁。

---

## 3. 后端：Schemas / Service / API

### 3.1 Pydantic schemas

新文件 [backend/app/schemas/share.py](../backend/app/schemas/share.py)：

```python
from datetime import datetime
from pydantic import BaseModel, field_validator

from app.models.pet import MemberRole


class ShareCodeResponse(BaseModel):
    code: str
    expires_at: datetime
    created_at: datetime

    model_config = {"from_attributes": True}


class ShareCodeRedeemRequest(BaseModel):
    code: str

    @field_validator("code")
    @classmethod
    def normalize(cls, v: str) -> str:
        v = (v or "").strip().upper()
        if len(v) != 8:
            raise ValueError("分享码必须为 8 位")
        return v


class PetMemberResponse(BaseModel):
    user_id: int
    nickname: str | None
    avatar_url: str | None
    role: MemberRole
    joined_at: datetime


class PetMembersResponse(BaseModel):
    members: list[PetMemberResponse]


class MemberUpdateRequest(BaseModel):
    role: MemberRole

    @field_validator("role")
    @classmethod
    def must_not_be_owner(cls, v: MemberRole) -> MemberRole:
        if v == MemberRole.OWNER:
            raise ValueError("不允许通过此接口设置 OWNER")
        return v
```

修改 [backend/app/schemas/pet.py](../backend/app/schemas/pet.py) `PetResponse`：
- 新增 `share_code_active: bool`，仅 OWNER 视角为可能 true，其他角色固定 false。
- `invite_code` 文档注释里追加 `# Deprecated since Phase 2 step1, kept for backward compatibility, will be removed.`。

### 3.2 Service：[backend/app/services/share.py](../backend/app/services/share.py)（新文件）

复用 [backend/app/utils/invite_code.py](../backend/app/utils/invite_code.py) 已有的 `INVITE_CODE_CHARS` 字符集（31 字符、剔除易混淆字符）；只需要支持长度 8。当前 `generate_invite_code(length=6)` 默认值可保留，调用方传 `length=8` 即可。

核心常量：

```python
SHARE_CODE_LENGTH = 8
SHARE_CODE_TTL_HOURS = 24
SHARE_CODE_GEN_RETRIES = 10

ROLE_LEVEL = {
    MemberRole.VIEWER: 1,
    MemberRole.EDITOR: 2,
    MemberRole.OWNER: 3,
}
```

> `ROLE_LEVEL` 也会被 [backend/app/services/pet.py](../backend/app/services/pet.py) 的 `get_pet_membership` 使用，建议放在 `pet.py` 顶部并由 `share.py` import。

主要函数（全部 async，签名给齐）：

```python
async def generate_share_code(db: AsyncSession, pet_id: int, user_id: int) -> ShareCodeResponse: ...
async def get_active_share_code(db: AsyncSession, pet_id: int, user_id: int) -> ShareCodeResponse | None: ...
async def revoke_active_share_code(db: AsyncSession, pet_id: int, user_id: int) -> None: ...
async def redeem_share_code(db: AsyncSession, code: str, user_id: int) -> PetResponse: ...
async def list_pet_members(db: AsyncSession, pet_id: int, user_id: int) -> list[PetMemberResponse]: ...
async def update_member_role(db: AsyncSession, pet_id: int, member_user_id: int, new_role: MemberRole, user_id: int) -> PetMemberResponse: ...
async def remove_member(db: AsyncSession, pet_id: int, member_user_id: int, user_id: int) -> None: ...
```

行为细节（实现时严格遵循）：

- **generate_share_code**
  1. `pet, _ = await get_pet_membership(pet_id, user_id, db, require_role=MemberRole.OWNER)`。
  2. `await db.execute(update(PetShareCode).where(PetShareCode.pet_id == pet_id, PetShareCode.revoked_at.is_(None), PetShareCode.used_at.is_(None), PetShareCode.expires_at > utcnow()).values(revoked_at=utcnow()))`。
  3. 生成唯一 8 位 code（最多 10 次重试，`select(...).where(code==candidate)` 检查；10 次都撞了抛 `AppException(500, "SHARE_CODE_GENERATION_FAILED", "分享码生成失败，请重试")`）。
  4. `expires_at = utcnow() + timedelta(hours=24)`。
  5. 写入并 `commit`，返回 `ShareCodeResponse`。

- **get_active_share_code**
  - 同样需要 OWNER（其他角色不应看到分享码本身）。
  - 选 `pet_id` + 活码条件 + `order_by(PetShareCode.created_at.desc()).limit(1)`。
  - 没有则返回 `None`，由 API 层映射为 `204 No Content`。

- **revoke_active_share_code**
  - OWNER-only。
  - 把所有当前活码 `revoked_at = utcnow()`；无活码也 `204`，不报错。

- **redeem_share_code**
  - 不需要 pet_id 参数，直接靠 code 查。
  - SQL：
    ```python
    stmt = (
        select(PetShareCode)
        .where(PetShareCode.code == code)
        .with_for_update()  # 防并发兑换
    )
    ```
    > SQLite 不支持 `FOR UPDATE`，测试时调用 `with_for_update()` 会被 SQLAlchemy 静默忽略，无影响。
  - 校验顺序（任何一个失败立刻 raise）：
    - 不存在 → `SHARE_CODE_NOT_FOUND`
    - `revoked_at is not None` → `SHARE_CODE_REVOKED`
    - `used_at is not None` → `SHARE_CODE_USED`
    - `expires_at <= utcnow()` → `SHARE_CODE_EXPIRED`
    - `pet.owner_id == user_id` → `SHARE_CODE_SELF_REDEEM`
    - 该 user 已经是 `PetMember(pet_id=pet.id)` → `SHARE_ALREADY_MEMBER`
  - 通过后：
    - `db.add(PetMember(pet_id=pet.id, user_id=user_id, role=MemberRole.VIEWER))`
    - `share_code.used_at = utcnow(); share_code.used_by_user_id = user_id`
    - 单事务 `commit`。
    - 返回 `_build_pet_response(pet, MemberRole.VIEWER)`（复用 [backend/app/services/pet.py](../backend/app/services/pet.py) 现有函数）。

- **list_pet_members**
  - OWNER-only。
  - SQL：`select(PetMember, User).join(User, User.id == PetMember.user_id).where(PetMember.pet_id == pet_id, PetMember.role != MemberRole.OWNER).order_by(PetMember.created_at.asc())`。
  - 返回的 `joined_at` = `PetMember.created_at`。

- **update_member_role**
  - OWNER-only。
  - `new_role` 必须是 `EDITOR` 或 `VIEWER`（Pydantic 已挡 OWNER）。
  - 找 `PetMember(pet_id, user_id=member_user_id)`，不存在 → `SHARE_MEMBER_NOT_FOUND`。
  - 当前角色是 OWNER → `SHARE_ROLE_INVALID`（不允许动 OWNER）。
  - 更新 + commit + 返回 `PetMemberResponse`。

- **remove_member**
  - OWNER-only。
  - `member_user_id == user_id` → `SHARE_ROLE_INVALID`（OWNER 不能"移除自己"，删除档案另走 `DELETE /pets/{id}`）。
  - 找不到 member 行 → `SHARE_MEMBER_NOT_FOUND`。
  - 当前是 OWNER → `SHARE_ROLE_INVALID`。
  - `db.delete(member)` + commit。

### 3.3 修改 `get_pet_membership` 为多级权限

修改 [backend/app/services/pet.py](../backend/app/services/pet.py)：

```python
ROLE_LEVEL: dict[MemberRole, int] = {
    MemberRole.VIEWER: 1,
    MemberRole.EDITOR: 2,
    MemberRole.OWNER: 3,
}


async def get_pet_membership(
    pet_id: int,
    user_id: int,
    db: AsyncSession,
    *,
    require_owner: bool = False,        # 兼容旧调用，等价于 require_role=OWNER
    require_role: MemberRole | None = None,
) -> tuple[Pet, PetMember]:
    ...
    needed = MemberRole.OWNER if require_owner else require_role
    if needed is not None and ROLE_LEVEL[member.role] < ROLE_LEVEL[needed]:
        if needed == MemberRole.OWNER:
            raise AppException(403, "PET_OWNER_REQUIRED", "只有档案所有者才能执行此操作")
        else:
            raise AppException(403, "PET_EDITOR_REQUIRED", "需要编辑权限才能执行此操作")
    return pet, member
```

> 兼容性：现有的 `require_owner=True` 调用全部保持不变（仍走 OWNER 分支并返回老错误码 `PET_OWNER_REQUIRED`），避免破坏既有 API 与既有测试。

### 3.4 全局权限矩阵（实现时逐条对照）

| 资源 / 接口 | 文件 | 现状 | 调整为 |
|---|---|---|---|
| `PUT /pets/{id}` | [backend/app/services/pet.py](../backend/app/services/pet.py) `update_pet` | OWNER | EDITOR |
| `POST /pets/{id}/avatar` | 同上 `upload_avatar` | OWNER | EDITOR |
| `DELETE /pets/{id}` | 同上 `delete_pet` | OWNER | OWNER（不变）|
| `POST /pets/{id}/photos` | [backend/app/api/v1/photos.py](../backend/app/api/v1/photos.py) `upload_photos` | 任意成员 | EDITOR |
| `DELETE /photos/{id}` | 同上 `delete_photo` | 任意成员 | EDITOR |
| `GET /pets/{id}/photos`、`GET /photos/{id}/url`、`GET /photos/timeline*` | 同上 | 任意成员 | 任意成员（不变）|
| `POST/PUT/DELETE /pets/{id}/weights*` | [backend/app/services/health.py](../backend/app/services/health.py) `create_weight` / `update_weight` / `delete_weight` | 任意成员 | EDITOR |
| `GET /pets/{id}/weights*` | 同上 `list_weights` | 任意成员 | 任意成员 |
| 同上 deworming / vaccination / routine 的 create/update/delete + cycle 写 | 同上 | 任意成员 | EDITOR |
| 同上 deworming / vaccination / routine 的 list / status / 单条 GET | 同上 | 任意成员 | 任意成员 |
| `POST /pets/{id}/share-code` 等 7 个分享接口 | 新文件 | — | 见 3.5 |

实现方法：把 `await get_pet_membership(pet_id, user_id, db)` 换成 `await get_pet_membership(pet_id, user_id, db, require_role=MemberRole.EDITOR)`（涉及位置参考第 1 节里 `Grep` 结果，每处都要改）。

### 3.5 API：[backend/app/api/v1/share.py](../backend/app/api/v1/share.py)（新文件）

```python
router = APIRouter(prefix="/pets", tags=["share"])
```

挂到 [backend/app/api/v1/router.py](../backend/app/api/v1/router.py)：

```python
from app.api.v1 import auth, pets, photos, health, share
api_v1_router.include_router(share.router)
```

接口清单：

| Method | Path | 权限 | 入参 | 返回 |
|---|---|---|---|---|
| `POST` | `/pets/{pet_id}/share-code` | OWNER | – | `201` `ShareCodeResponse` |
| `GET` | `/pets/{pet_id}/share-code` | OWNER | – | `200` `ShareCodeResponse` 或 `204 No Content` |
| `DELETE` | `/pets/{pet_id}/share-code` | OWNER | – | `204` |
| `POST` | `/pets/redeem` | 已登录用户 | `{ "code": "ABCD1234" }` | `200` `PetResponse` |
| `GET` | `/pets/{pet_id}/members` | OWNER | – | `200` `PetMembersResponse` |
| `PATCH` | `/pets/{pet_id}/members/{member_user_id}` | OWNER | `{ "role": "editor" \| "viewer" }` | `200` `PetMemberResponse` |
| `DELETE` | `/pets/{pet_id}/members/{member_user_id}` | OWNER | – | `204` |

注意：
- `POST /pets/redeem` 路径不含 `pet_id`（用户兑换前不知道 pet_id）。挂在 `/pets` 前缀下方便归类。FastAPI 会按声明顺序匹配，确保该路由在 `/pets/{pet_id}` 之前注册（或显式用 `redeem` 这种非数字字面量也不会冲突，因为 `pet_id: int` 类型校验会失败回退）。为安全起见，**实现时先注册 `redeem` 路由，再注册 `{pet_id}` 路由**。
- `GET /share-code` 没有活码时返回 `204 No Content`（FastAPI 通过 `Response(status_code=204)` 实现），前端按 204 视为"无活码"。
- 错误一律走 `AppException`，不直接抛 `HTTPException`。

---

## 4. 前端：模型 / 服务 / Provider

### 4.1 模型扩展

[frontend/lib/models/pet.dart](../frontend/lib/models/pet.dart)：

- 在文件顶部加：
  ```dart
  enum PetRole { owner, editor, viewer }

  PetRole petRoleFromString(String s) {
    switch (s) {
      case 'owner': return PetRole.owner;
      case 'editor': return PetRole.editor;
      case 'viewer': return PetRole.viewer;
    }
    throw ArgumentError('Unknown pet role: $s');
  }

  String petRoleLabel(PetRole r) {
    switch (r) {
      case PetRole.owner: return '拥有';
      case PetRole.editor: return '编辑';
      case PetRole.viewer: return '查看';
    }
  }
  ```
- `Pet` 类新增 `final bool shareCodeActive;`，`fromJson` 里读 `(json['share_code_active'] as bool?) ?? false`，`toJson` 同步加。
- 不要去掉 `myRole: String`（避免污染既有调用），新加一个 getter：
  ```dart
  PetRole get role => petRoleFromString(myRole);
  String get roleLabel => petRoleLabel(role);
  ```

### 4.2 新模型 [frontend/lib/models/share.dart](../frontend/lib/models/share.dart)

```dart
class ShareCode {
  final String code;
  final DateTime expiresAt;
  final DateTime createdAt;
  const ShareCode({required this.code, required this.expiresAt, required this.createdAt});
  factory ShareCode.fromJson(Map<String, dynamic> json) => ShareCode(
        code: json['code'] as String,
        expiresAt: DateTime.parse(json['expires_at'] as String).toLocal(),
        createdAt: DateTime.parse(json['created_at'] as String).toLocal(),
      );
}

class SharedMember {
  final int userId;
  final String? nickname;
  final String? avatarUrl;
  final PetRole role;
  final DateTime joinedAt;
  const SharedMember({...});
  factory SharedMember.fromJson(Map<String, dynamic> json) => SharedMember(
        userId: json['user_id'] as int,
        nickname: json['nickname'] as String?,
        avatarUrl: json['avatar_url'] as String?,
        role: petRoleFromString(json['role'] as String),
        joinedAt: DateTime.parse(json['joined_at'] as String).toLocal(),
      );
}
```

### 4.3 API 层 [frontend/lib/services/share_service.dart](../frontend/lib/services/share_service.dart)

```dart
class ShareService {
  final Dio _dio = ApiClient().dio;

  Future<ShareCode> generateCode(int petId) async { ... POST /pets/$petId/share-code }
  Future<ShareCode?> getActiveCode(int petId) async {
    final resp = await _dio.get('/pets/$petId/share-code',
        options: Options(validateStatus: (s) => s == 200 || s == 204));
    if (resp.statusCode == 204) return null;
    return ShareCode.fromJson(resp.data as Map<String, dynamic>);
  }
  Future<void> revokeCode(int petId) async { ... DELETE /pets/$petId/share-code }
  Future<Pet> redeemCode(String code) async { ... POST /pets/redeem body {code} }
  Future<List<SharedMember>> listMembers(int petId) async { ... GET /pets/$petId/members }
  Future<SharedMember> updateMemberRole(int petId, int userId, PetRole role) async { ... PATCH body {role: role.name} }
  Future<void> removeMember(int petId, int userId) async { ... DELETE }
}
```

### 4.4 Provider [frontend/lib/providers/share_provider.dart](../frontend/lib/providers/share_provider.dart)

```dart
final shareServiceProvider = Provider<ShareService>((_) => ShareService());

// 当前活码：family by petId
final shareCodeProvider =
    AsyncNotifierProvider.family<ShareCodeNotifier, ShareCode?, int>(ShareCodeNotifier.new);

class ShareCodeNotifier extends FamilyAsyncNotifier<ShareCode?, int> {
  @override
  Future<ShareCode?> build(int petId) =>
      ref.read(shareServiceProvider).getActiveCode(petId);

  Future<void> regenerate() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      return await ref.read(shareServiceProvider).generateCode(arg);
    });
  }

  Future<void> revoke() async {
    await ref.read(shareServiceProvider).revokeCode(arg);
    state = const AsyncData(null);
  }
}

final sharedMembersProvider =
    AsyncNotifierProvider.family<SharedMembersNotifier, List<SharedMember>, int>(
        SharedMembersNotifier.new);
// 类似实现，含 refresh / removeMember(userId) / updateRole(userId, role)
```

兑换分享码不需要常驻状态，直接在 UI 里 `await ref.read(shareServiceProvider).redeemCode(code)`，成功后 `ref.read(petListProvider.notifier).refresh()`。

---

## 5. 前端：UI 与路由

### 5.1 入口：[frontend/lib/screens/profile/profile_screen.dart](../frontend/lib/screens/profile/profile_screen.dart)

在 `_buildMenuItem(... '宠物档案管理' ...)` 后新增一行：

```dart
const Divider(height: 1, indent: 56),
_buildMenuItem(
  context,
  icon: Icons.ios_share,
  title: '宠物档案分享',
  onTap: () => context.push('/profile/pets/share'),
),
```

### 5.2 路由：[frontend/lib/config/router.dart](../frontend/lib/config/router.dart)

在 `/profile/pets/:petId/edit` 之后追加：

```dart
GoRoute(
  path: '/profile/pets/share',
  parentNavigatorKey: _rootNavigatorKey,
  builder: (context, state) => const PetShareListScreen(),
),
GoRoute(
  path: '/profile/pets/:petId/share',
  parentNavigatorKey: _rootNavigatorKey,
  builder: (context, state) =>
      PetShareDetailScreen(petId: int.parse(state.pathParameters['petId']!)),
),
```

并补 import。

### 5.3 新页面 1：`PetShareListScreen`

文件：`frontend/lib/screens/profile/share/pet_share_list_screen.dart`

- 跟 [pet_manage_screen.dart](../frontend/lib/screens/profile/pet_manage_screen.dart) 同布局：`AppBar('宠物档案分享')` + 列表卡片。
- **过滤**：只展示 `pet.role == PetRole.owner` 的宠物（拥有的才能分享）。
- 卡片上**不**展示"拥有/编辑/查看"角标（角标是档案管理页特性）。
- 卡片不可滑动删除；不需要底部"添加宠物"按钮。
- `onTap`：`context.push('/profile/pets/${pet.id}/share')`。
- 空态文案：「还没有自己创建的宠物档案，分享功能仅对您拥有的宠物可用」。

### 5.4 新页面 2：`PetShareDetailScreen`

文件：`frontend/lib/screens/profile/share/pet_share_detail_screen.dart`

页面结构：

```
┌──────────────────────────────────┐
│  AppBar: 「{宠物名} · 档案分享」  │
├──────────────────────────────────┤
│  卡片：分享码                     │
│  ┌──────────────────────────────┐│
│  │  ABCD1234   (大号等宽 letter-spaced) │
│  │  剩余：23 时 47 分            ││
│  │  [复制]  [重新生成]            ││
│  └──────────────────────────────┘│
│  说明文字：分享码默认只读，1 天内有效    │
├──────────────────────────────────┤
│  已分享给（n 人）                 │
│  [头像] 昵称        编辑 chip      │
│  [头像] 昵称        查看 chip      │
│  ……                              │
└──────────────────────────────────┘
```

实现要点：

- 顶部：`ref.watch(shareCodeProvider(petId))`。
  - `null` → 中央按钮「生成 8 位分享码」。
  - 有值 → 大号 code + 倒计时（用 `Timer.periodic(const Duration(seconds: 30), ...)` 重新计算 `remaining = expiresAt.difference(DateTime.now())`；离开页面时 `cancel`）。
  - 「复制」用 `Clipboard.setData(ClipboardData(text: code.code))` + snackbar。
  - 「重新生成」前弹确认 dialog：「重新生成会立即作废当前分享码，是否继续？」；确认后 `await ref.read(shareCodeProvider(petId).notifier).regenerate()`。
- 下方：`ref.watch(sharedMembersProvider(petId))`。
  - 空态文案：「还没有用户接受这份档案分享」。
  - 列表项 `GestureDetector(onLongPress: ...)` 弹 `showModalBottomSheet`：
    ```
    [授予编辑权限 / 取消编辑权限]   ← 视当前 role 而定
    [删除分享权限]                  ← 红字
    [取消]
    ```
  - "授予编辑权限"调 `updateMemberRole(userId, PetRole.editor)`；"取消编辑权限"调 `updateMemberRole(userId, PetRole.viewer)`；"删除分享权限"二次确认 dialog 后 `removeMember(userId)`，操作完成后 `sharedMembersProvider(petId).notifier.refresh()`。
  - 操作成功统一 snackbar（`已授予 xxx 编辑权限` / `已移除 xxx 的分享权限`）。
  - 失败按错误码映射到友好提示（见第 6 节）。

### 5.5 创建宠物页：[pet_edit_screen.dart](../frontend/lib/screens/profile/pet_edit_screen.dart)

在 `_buildSaveButton()` 调用之后、且仅 `!_isEditing` 时插入：

```dart
const SizedBox(height: 12),
_buildRedeemButton(),
```

新方法：

```dart
Widget _buildRedeemButton() {
  return SizedBox(
    height: 48,
    child: OutlinedButton.icon(
      onPressed: _isLoading ? null : _showRedeemDialog,
      icon: const Icon(Icons.qr_code_2),
      label: const Text('通过分享码添加档案'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.primaryColor,
        side: const BorderSide(color: AppTheme.primaryColor),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
```

`_showRedeemDialog()`：
- 一个 `AlertDialog`，标题"输入分享码"，内容是一个 `TextField`：
  - `textCapitalization: TextCapitalization.characters`
  - `inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[A-Z0-9]')), LengthLimitingTextInputFormatter(8)]`
  - `style: TextStyle(fontFamily: 'monospace', letterSpacing: 4, fontSize: 20)`
  - `decoration: InputDecoration(hintText: 'ABCD1234', counterText: '')`
- "确定"按钮：长度不足 8 位时禁用（用 `StatefulBuilder` 跟踪输入值）。
- 提交：`await ref.read(shareServiceProvider).redeemCode(code)` → 成功 `ref.read(petListProvider.notifier).refresh()` → snackbar"已添加共享档案：{petName}" → `Navigator.of(context).pop(true)` 关闭整个创建页（pop 整个 PetEditScreen，让用户回到管理页）。
- 失败按 `DioException` 取 `error.response?.data['code']` 用统一 mapper（第 6 节）。

### 5.6 档案管理页角标：[pet_manage_screen.dart](../frontend/lib/screens/profile/pet_manage_screen.dart)

- 删除当前 `if (!pet.isOwner)` 的"共享"灰标签代码块。
- 在 `_buildPetCard` 的 `Card` 外面包一层 `Stack`，`Positioned(top: 8, right: 8, child: _buildRoleBadge(pet.role))`：

```dart
Widget _buildRoleBadge(PetRole role) {
  late final Color bg, fg;
  switch (role) {
    case PetRole.owner:
      bg = const Color(0xFFFFE5E5); fg = const Color(0xFFD64545); break;
    case PetRole.editor:
      bg = const Color(0xFFE5F0FF); fg = const Color(0xFF2D6BD6); break;
    case PetRole.viewer:
      bg = const Color(0xFFE8F5EA); fg = const Color(0xFF3E8E50); break;
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
    child: Text(petRoleLabel(role),
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
  );
}
```

- 卡片 `onTap` 行为保持不变（仅 owner 进入编辑页）；`Dismissible` 仍仅 owner 可删。说明文字（如有）按需更新成"仅档案所有者可删除"。

---

## 6. 错误码与前端 mapper

后端新错误码（全部走 `AppException`，HTTP 4xx）：

| code | HTTP | message | 触发场景 |
|---|---|---|---|
| `SHARE_CODE_GENERATION_FAILED` | 500 | 分享码生成失败，请重试 | 10 次随机都撞 |
| `SHARE_CODE_NOT_FOUND` | 404 | 分享码不存在 | 兑换时找不到 |
| `SHARE_CODE_EXPIRED` | 400 | 分享码已过期 | `expires_at <= now` |
| `SHARE_CODE_USED` | 400 | 分享码已被使用 | `used_at` 非空 |
| `SHARE_CODE_REVOKED` | 400 | 分享码已被撤回 | `revoked_at` 非空 |
| `SHARE_CODE_SELF_REDEEM` | 400 | 不能兑换自己宠物的分享码 | `pet.owner_id == user_id` |
| `SHARE_ALREADY_MEMBER` | 400 | 您已经是该宠物档案的共享成员 | 重复兑换 |
| `SHARE_MEMBER_NOT_FOUND` | 404 | 分享成员不存在 | 改 / 删除时找不到 |
| `SHARE_ROLE_INVALID` | 400 | 不允许此角色变更 | OWNER 自己 / 升 OWNER |
| `PET_OWNER_REQUIRED` | 403 | 只有档案所有者才能执行此操作 | 非 OWNER 调 OWNER 接口（沿用现有错误码）|
| `PET_EDITOR_REQUIRED` | 403 | 需要编辑权限才能执行此操作 | VIEWER 调写接口（新错误码）|

前端 mapper：

`frontend/lib/services/share_service.dart` 顶部 / 同 service 文件末尾或公共 utils 提供：

```dart
String shareErrorToMessage(Object error) {
  if (error is DioException && error.response?.data is Map) {
    final code = (error.response!.data as Map)['code'] as String?;
    switch (code) {
      case 'SHARE_CODE_NOT_FOUND': return '分享码不存在';
      case 'SHARE_CODE_EXPIRED':   return '分享码已过期';
      case 'SHARE_CODE_USED':      return '分享码已被使用';
      case 'SHARE_CODE_REVOKED':   return '分享码已被撤回';
      case 'SHARE_CODE_SELF_REDEEM': return '不能添加自己的宠物档案';
      case 'SHARE_ALREADY_MEMBER':   return '您已是该档案的共享成员';
      case 'SHARE_MEMBER_NOT_FOUND': return '该成员已不存在，请刷新重试';
      case 'SHARE_ROLE_INVALID':     return '不允许此角色变更';
      case 'PET_OWNER_REQUIRED':     return '仅档案所有者可执行此操作';
      case 'PET_EDITOR_REQUIRED':    return '当前权限不足，无法执行';
    }
  }
  return '操作失败，请稍后重试';
}
```

---

## 7. 不在本步骤范围（Out of Scope）

> 实现时不要扩散到以下功能。如果用户在 issue 里提到，请明确驳回。

- 所有权转让（OWNER → 其它用户）。
- 通过微信小程序 / 系统分享 / 二维码扫码兑换。
- 群组、家庭空间、批量管理。
- 让 EDITOR 也能在前端进入「宠物编辑页」修改名字 / 头像（后端权限已开，但前端入口仍仅 OWNER 可见，留给后续步骤统一打磨）。
- 把分享给的好友的设备也加入推送通知调度。
- `Pet.invite_code` 字段的真正下线（保留兼容）。
- `pet_share_codes` 行的后台清理任务（暂用永久保留 + 索引覆盖足够）。

---

## 8. 测试计划

### 8.1 既有测试需要修复

- [backend/tests/api/test_pets.py](../backend/tests/api/test_pets.py) `test_member_can_read_but_not_write`：
  - 把 `MemberRole.MEMBER` 改为 `MemberRole.VIEWER`；
  - `assert body["my_role"] == "member"` 改 `"viewer"`；
  - **拆出新用例** 验证 EDITOR：
    - 注入 `PetMember(role=EDITOR)`，`PUT /pets/{id}` 应 `200`；`POST /pets/{id}/avatar` 应 `200`；`DELETE /pets/{id}` 仍 `403 PET_OWNER_REQUIRED`。
- 任何其他 `MemberRole.MEMBER` 出现处一并迁移（在仓库内 `rg "MemberRole.MEMBER"` 一遍兜底）。

### 8.2 新单测

新建 [backend/tests/api/test_pet_share.py](../backend/tests/api/test_pet_share.py)：

- `test_owner_can_generate_and_revoke_code`
- `test_only_owner_can_generate`（VIEWER / EDITOR 调用 `POST /pets/{id}/share-code` → 403）
- `test_get_active_returns_204_when_none`
- `test_regenerate_revokes_previous`（连续两次 generate；老 code 兑换返回 `SHARE_CODE_REVOKED`）
- `test_redeem_success_creates_viewer_member`（兑换后 `GET /pets` 出现该宠物，`my_role == "viewer"`）
- `test_redeem_self_forbidden`（OWNER 兑换自己的码 → 400）
- `test_redeem_already_member_forbidden`（EDITOR 再次兑换 → 400）
- `test_redeem_expired`（手动把 `expires_at` 改到过去 → 400）
- `test_redeem_used_only_once`（B 兑换成功 → C 再兑换同码 → 400 USED）
- `test_redeem_revoked`（OWNER 撤销 → 兑换 400 REVOKED）
- `test_list_members_owner_only`（VIEWER 调 → 403；OWNER 调返回不含自己的列表）
- `test_update_member_role_editor_then_back`
- `test_update_role_to_owner_rejected`（PATCH role=owner → 400 由 schema 校验抛 `VALIDATION_ERROR`）
- `test_remove_member`
- `test_remove_self_rejected`（OWNER 试图 DELETE 自己 → 400 SHARE_ROLE_INVALID）
- `test_editor_can_write_pet_and_records`（EDITOR PUT pet / POST photo / POST weight 全部 200；DELETE pet 仍 403）
- `test_viewer_cannot_write`（VIEWER 上述写接口全部 403 PET_EDITOR_REQUIRED）

### 8.3 手动验收剧本

1. 用户 A 登录 → 创建宠物"橘子" → 进入「我的 → 宠物档案分享 → 橘子」→ 点"生成 8 位分享码"，看到 8 位码 + 24h 倒计时；复制成功。
2. A 退出登录；用户 B 登录 → 进入「我的 → 宠物档案管理 → 添加宠物 → 通过分享码添加档案」→ 输入 A 的码 → 弹出"已添加共享档案：橘子" → 回到管理页，看见"橘子"卡片右上角"查看"角标。
3. B 尝试编辑橘子（点击卡片 → 应不可进入编辑；如临时 hack 调 PUT，会 403 PET_EDITOR_REQUIRED）。
4. A 进入「橘子分享详情」→ 看到 B 头像 + "查看" chip → 长按 B → "授予编辑权限" → chip 变"编辑"。
5. B 这边下拉刷新档案管理页 → 角标变"编辑"。（B 的写权限随后端立即生效）
6. A 长按 B → "取消编辑权限" → chip 回到"查看"；B 角标回到"查看"。
7. A 长按 B → "删除分享权限" → 确认 → 列表中 B 消失；B 下拉刷新 → 橘子从档案列表消失。
8. A 在分享码卡片点"重新生成" → 老码失效（用老码再次兑换提示"分享码已被撤回"）。
9. A 自己尝试用自己的码 → 提示"不能添加自己的宠物档案"。
10. 等到第二天再试老码 → "分享码已过期"（或人工把 `expires_at` 改到过去验证）。

---

## 9. 实施顺序建议

下一位 agent 接手时按这个顺序，可让"每一步都能起服务并跑测"。

1. **数据 + 迁移**：改模型 → 写 alembic 迁移 → 本地 `alembic upgrade head` 验证 → 修复测试基线（替换 `MEMBER` → `VIEWER`）。
2. **后端 service 重构**：实现 `ROLE_LEVEL` + `get_pet_membership(require_role=...)`，改写所有写接口到 EDITOR 门槛 → 跑既有 health/photos 测试确保没炸。
3. **分享 service + API**：写 `share.py` service / schema / api → 写新单测 → 全绿。
4. **前端模型/服务/provider**：先把 `Pet.shareCodeActive` 字段加进去保证不破坏既有列表渲染。
5. **前端入口 + 路由 + 三个新页面**：`profile_screen` → `PetShareListScreen` → `PetShareDetailScreen` → `pet_edit_screen` 的兑换按钮 → `pet_manage_screen` 角标重做。
6. **真机走一遍 8.3 剧本**。
7. **commit**：建议拆成"backend: pet sharing"+"frontend: pet sharing UI" 两个提交，便于 revert。

---

## 附录 A：响应示例

**`POST /api/v1/pets/12/share-code`** → `201`

```json
{
  "code": "K7M2X9P4",
  "expires_at": "2026-04-19T08:00:00",
  "created_at": "2026-04-18T08:00:00"
}
```

**`POST /api/v1/pets/redeem`** body `{"code": "K7M2X9P4"}` → `200`

```json
{
  "id": 12,
  "name": "橘子",
  "pet_type": "cat",
  "breed": "中华田园猫",
  "birthday": "2022-05-01",
  "avatar_url": "https://.../avatars/pets/12/...jpg",
  "invite_code": null,
  "...": "(其它字段同 PetResponse)",
  "is_owner": false,
  "my_role": "viewer",
  "share_code_active": false,
  "created_at": "2026-04-18T08:00:00",
  "updated_at": "2026-04-18T08:00:00"
}
```

**`GET /api/v1/pets/12/members`** → `200`

```json
{
  "members": [
    {
      "user_id": 7,
      "nickname": "小明",
      "avatar_url": "https://.../avatars/users/7.jpg",
      "role": "viewer",
      "joined_at": "2026-04-18T08:01:23"
    },
    {
      "user_id": 9,
      "nickname": "妈妈",
      "avatar_url": null,
      "role": "editor",
      "joined_at": "2026-04-17T10:00:00"
    }
  ]
}
```

**错误示例** `POST /api/v1/pets/redeem` 用过的码 → `400`

```json
{
  "code": "SHARE_CODE_USED",
  "message": "分享码已被使用",
  "details": null
}
```
