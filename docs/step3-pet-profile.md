# Step 3: 宠物档案管理

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL 技术栈。本步骤实现宠物档案的 CRUD 管理功能。

**前置依赖**: Step 2 已完成，用户可以通过手机号登录，JWT 认证已可用。

---

## 本步骤目标

1. 后端实现宠物档案 CRUD API
2. Flutter 实现「我的」页面中的宠物档案管理
3. Flutter 实现通用的宠物档案选择器组件 (供其他页面复用)
4. 为 Phase 2 的邀请码共享功能预留接口

---

## 0. 本步骤明确边界

为避免 agent 在实现时自行扩展或误判，本步骤按以下口径执行：

- `member` 在 Step 3 中只读；只有 `owner` 可以编辑和删除宠物档案
- `GET /api/v1/pets` 按全局规则支持 `page` + `page_size`
- `POST /api/v1/pets` 成功后返回与详情接口一致的完整 `PetResponse`
- `PetSelector` 本步需要接入「记录」「健康」「时间轴」
- 当前选中的宠物需要本地持久化，应用重启后恢复
- 时间轴页虽然仍是占位页，但本步的多选状态设计要按 Step 6 的真实筛选方式组织
- Phase 2 的“通过邀请码加入宠物档案”接口本步不实现，只保留 `invite_code` 字段与返回规则

---

## 1. 数据模型回顾

### pets 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | bigint PK | 自增主键 |
| owner_id | bigint FK → users.id | 创建者 |
| name | varchar(50) | 宠物名字 |
| pet_type | enum(cat/dog) | 猫或狗 |
| breed | varchar(50) | 品种 (可选) |
| birthday | date | 生日 (可选) |
| avatar_url | varchar(500) | 头像 URL (可选) |
| invite_code | varchar(20) UK | 邀请码 (自动生成) |
| internal_deworming_cycle_days | int | 内驱周期天数 (可选) |
| external_deworming_cycle_days | int | 外驱周期天数 (可选) |
| created_at | timestamp | 创建时间 |
| updated_at | timestamp | 更新时间 |

### pet_members 表

| 字段 | 类型 | 说明 |
|------|------|------|
| id | bigint PK | 自增主键 |
| pet_id | bigint FK → pets.id | 宠物档案 |
| user_id | bigint FK → users.id | 用户 |
| role | enum(owner/member) | 角色 |
| created_at | timestamp | 加入时间 |

**关系**: 创建宠物档案时，自动在 pet_members 中创建一条 role=owner 的记录。查询用户的宠物档案时，通过 pet_members 表关联。

**Step 3 权限约定**:

- `owner` 可以查看、创建、编辑、删除自己的宠物档案
- `member` 只能查看，不能编辑、上传头像、删除
- 后续步骤中如果 `member` 需要维护普通记录（照片、体重等），不影响本步骤的档案权限口径

---

## 2. 后端 API 规格

所有 API 需要 `Authorization: Bearer {access_token}` 头。

### 2.0 通用约定

- 所有字段使用 `snake_case`
- 业务错误继续沿用 Step 2 的统一结构：`code`、`message`、`details`
- 列表接口默认使用 `page` + `page_size`
- 列表响应保留语义 key `pets`
- 创建 / 更新成功默认返回最新完整对象
- `avatar_url` 必须是客户端可直接访问的统一入口地址，例如 `/media/...` 对应的公网 URL，不能返回 MinIO 内部地址

本步骤统一使用以下 `PetResponse` 结构：

```json
{
  "id": 1,
  "name": "橘子",
  "pet_type": "cat",
  "breed": "中华田园猫",
  "birthday": "2023-03-15",
  "avatar_url": null,
  "invite_code": "A3X7K9",
  "internal_deworming_cycle_days": null,
  "external_deworming_cycle_days": null,
  "is_owner": true,
  "my_role": "owner",
  "created_at": "2024-01-01T00:00:00Z",
  "updated_at": "2024-01-01T00:00:00Z"
}
```

其中：

- `invite_code` 仅在当前用户是 `owner` 时返回真实值，否则返回 `null`
- `is_owner` 用于前端快速判断危险操作和编辑态
- `my_role` 仅取 `owner` / `member`

### 2.1 创建宠物档案

```
POST /api/v1/pets
Content-Type: application/json
```

请求体:
```json
{
  "name": "橘子",
  "pet_type": "cat",
  "breed": "中华田园猫",
  "birthday": "2023-03-15"
}
```

成功响应 (201):
```json
{
  "id": 1,
  "name": "橘子",
  "pet_type": "cat",
  "breed": "中华田园猫",
  "birthday": "2023-03-15",
  "avatar_url": null,
  "invite_code": "A3X7K9",
  "internal_deworming_cycle_days": null,
  "external_deworming_cycle_days": null,
  "is_owner": true,
  "my_role": "owner",
  "created_at": "2024-01-01T00:00:00Z",
  "updated_at": "2024-01-01T00:00:00Z"
}
```

业务逻辑:
- 验证 `name` 不为空且长度 `<= 50`
- `pet_type` 必须是 `"cat"` 或 `"dog"`
- `breed` 和 `birthday` 可选
- 自动生成 6 位唯一邀请码 (大写字母+数字组合，排除易混淆字符如 `0/O`、`1/I/L`)
- 创建 `pets` 记录
- 创建 `pet_members` 记录 (`role=owner`)
- 驱虫周期默认为 `null` (用户后续在健康管理中设置)

### 2.2 获取我的所有宠物档案

```
GET /api/v1/pets?page=1&page_size=20
```

成功响应 (200):
```json
{
  "page": 1,
  "page_size": 20,
  "total": 2,
  "pets": [
    {
      "id": 1,
      "name": "橘子",
      "pet_type": "cat",
      "breed": "中华田园猫",
      "birthday": "2023-03-15",
      "avatar_url": "https://example.com/media/avatars/pet_1.jpg",
      "invite_code": "A3X7K9",
      "internal_deworming_cycle_days": 30,
      "external_deworming_cycle_days": 30,
      "is_owner": true,
      "my_role": "owner",
      "created_at": "2024-01-01T00:00:00Z",
      "updated_at": "2024-01-01T00:00:00Z"
    },
    {
      "id": 2,
      "name": "旺财",
      "pet_type": "dog",
      "breed": "柴犬",
      "birthday": "2022-08-20",
      "avatar_url": null,
      "invite_code": null,
      "internal_deworming_cycle_days": null,
      "external_deworming_cycle_days": null,
      "is_owner": false,
      "my_role": "member",
      "created_at": "2024-01-02T00:00:00Z",
      "updated_at": "2024-01-02T00:00:00Z"
    }
  ]
}
```

业务逻辑:

- 通过 `pet_members` 表查询当前用户关联的所有宠物档案
- 支持 `page`、`page_size` 查询参数
- 包含 `is_owner` 字段标识用户是否为档案创建者
- 包含 `my_role` 字段，便于前端判断当前用户是 `owner` 还是 `member`
- 按创建时间倒序排列（最新创建的在前）
- `invite_code` 只在 `is_owner=true` 时返回（Phase 2 中使用）
- 空列表时返回 `200` + `pets: []`

### 2.3 获取单个宠物档案详情

```
GET /api/v1/pets/{pet_id}
```

成功响应 (200): 同上单个对象

错误响应:

- `403`: 用户不是该档案的成员
- `404`: 宠物档案不存在

### 2.4 更新宠物档案

```
PUT /api/v1/pets/{pet_id}
Content-Type: application/json
```

请求体 (所有字段可选):
```json
{
  "name": "大橘",
  "breed": "英短蓝猫",
  "birthday": "2023-04-01"
}
```

业务逻辑:

- 只有 `owner` 可以修改
- `pet_type` 不允许修改 (猫不能变成狗)
- `invite_code` 不允许修改
- 部分更新，只更新传入的字段
- Step 3 的编辑页只修改 `name`、`breed`、`birthday`
- 成功后返回最新完整 `PetResponse`

### 2.5 上传宠物头像

```
POST /api/v1/pets/{pet_id}/avatar
Content-Type: multipart/form-data
```

表单字段:

- `file`: 图片文件 (`jpg` / `png` / `webp`, `<= 5MB`)

成功响应 (200):
```json
{
  "id": 1,
  "name": "橘子",
  "pet_type": "cat",
  "breed": "中华田园猫",
  "birthday": "2023-03-15",
  "avatar_url": "https://example.com/media/avatars/pet_1_avatar.jpg",
  "invite_code": "A3X7K9",
  "internal_deworming_cycle_days": null,
  "external_deworming_cycle_days": null,
  "is_owner": true,
  "my_role": "owner",
  "created_at": "2024-01-01T00:00:00Z",
  "updated_at": "2024-01-02T00:00:00Z"
}
```

业务逻辑:

- 只有 `owner` 可以上传头像
- 验证文件类型和大小
- 上传到 MinIO `avatars` bucket
- 更新 `pet.avatar_url`
- 如果之前有头像，删除旧文件
- 成功后返回最新完整 `PetResponse`

### 2.6 删除宠物档案

```
DELETE /api/v1/pets/{pet_id}
```

成功响应 (204): No Content

业务逻辑:

- **只有 owner 可以删除**
- 删除档案时级联删除: 所有 `pet_members`、`photos`、`weights`、`dewormings`、`vaccinations`
- 删除 MinIO 中对应的照片文件
- 删除宠物头像文件
- 弹窗二次确认由前端处理

---

## 3. 后端实现要点

### 3.1 Pydantic Schema (`app/schemas/pet.py`)

```python
from datetime import date, datetime

from pydantic import BaseModel, field_validator

from app.models.pet import MemberRole, PetType


class PetCreate(BaseModel):
    name: str
    pet_type: PetType
    breed: str | None = None
    birthday: date | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str) -> str:
        value = value.strip()
        if not value or len(value) > 50:
            raise ValueError("宠物名字长度为1-50个字符")
        return value


class PetUpdate(BaseModel):
    name: str | None = None
    breed: str | None = None
    birthday: date | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, value: str | None) -> str | None:
        if value is None:
            return value
        value = value.strip()
        if not value or len(value) > 50:
            raise ValueError("宠物名字长度为1-50个字符")
        return value


class PetResponse(BaseModel):
    id: int
    name: str
    pet_type: PetType
    breed: str | None
    birthday: date | None
    avatar_url: str | None
    invite_code: str | None
    internal_deworming_cycle_days: int | None
    external_deworming_cycle_days: int | None
    is_owner: bool
    my_role: MemberRole
    created_at: datetime
    updated_at: datetime

    class Config:
        from_attributes = True


class PetListResponse(BaseModel):
    page: int
    page_size: int
    total: int
    pets: list[PetResponse]
```

实现建议：

- 不再向前端暴露 `owner_id`
- `PetResponse` 的组装建议单独封装序列化函数，根据当前用户角色决定 `invite_code` 是否置空
- 分页返回结构在 Step 3 固定下来，后续 Step 4-6 的列表接口继续复用同一风格

### 3.2 邀请码生成

```python
import random

INVITE_CODE_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # 排除 0/O/1/I/L


def generate_invite_code(length: int = 6) -> str:
    return "".join(random.choices(INVITE_CODE_CHARS, k=length))
```

生成后需检查数据库唯一性，冲突则重新生成。

### 3.3 权限检查辅助函数

```python
async def get_pet_membership(
    pet_id: int,
    user_id: int,
    db: AsyncSession,
    require_owner: bool = False,
) -> tuple[Pet, PetMember]:
    ...
```

实现建议：

- 不再使用 `HTTPException`，统一使用项目现有的 `AppException`
- 查询时建议一次性拿到 `Pet` + `PetMember`，避免路由层重复查询
- `require_owner=True` 仅用于 `PUT /pets/{pet_id}`、`POST /pets/{pet_id}/avatar`、`DELETE /pets/{pet_id}`
- `GET /pets/{pet_id}` 允许 `owner` 和 `member` 查看

推荐错误码：

- `PET_NOT_FOUND`
- `PET_FORBIDDEN`
- `PET_OWNER_REQUIRED`
- `PET_AVATAR_INVALID`
- `PET_AVATAR_TOO_LARGE`

### 3.4 分页查询与响应组装

实现建议：

- 在 `GET /api/v1/pets` 中先按 `pet_members.user_id = current_user.id` 过滤
- `total` 与 `pets` 列表使用同一套过滤条件
- 排序固定为 `pets.created_at DESC, pets.id DESC`
- 推荐在服务层封装分页查询函数，例如：

```python
async def list_user_pets(
    db: AsyncSession,
    user_id: int,
    page: int,
    page_size: int,
) -> tuple[list[PetResponse], int]:
    ...
```

### 3.5 存储与头像 URL 规则

推荐新增 `app/services/storage.py`，对外只暴露：

- `upload_pet_avatar(...)`
- `delete_object_by_url(...)`

约束：

- 上传时生成稳定 object key，例如 `avatars/pets/{pet_id}/{timestamp}.jpg`
- 返回给前端的 URL 必须基于统一入口地址拼接，例如 `PUBLIC_BASE_URL + /media/...`
- 替换头像时，先上传新图，再更新数据库，再删除旧图，避免用户出现短暂无头像状态
- 删除宠物档案时，除级联删除表记录外，还需要显式清理头像与照片文件

### 3.6 推荐后端实现顺序

1. 先修正 `app/schemas/pet.py`，统一请求/响应结构
2. 新增邀请码与权限辅助逻辑
3. 完善 `app/api/v1/pets.py` 中的创建、分页列表、详情、更新、头像上传、删除
4. 补充或更新自动化测试，至少覆盖 owner/member 权限差异与分页行为

---

## 4. Flutter 页面设计

### 4.1 「我的」页面 (`screens/profile/profile_screen.dart`)

```
┌─────────────────────────────────┐
│  我的                            │
├─────────────────────────────────┤
│                                 │
│   ┌─────┐                      │
│   │ 头像 │  用户昵称             │
│   └─────┘  手机号 138****8000    │
│                                 │
├─────────────────────────────────┤
│                                 │
│   📋 宠物档案管理           >    │
│                                 │
│   🔄 切换账号               >    │
│                                 │
│   ℹ️  关于                  >    │
│                                 │
└─────────────────────────────────┘
```

- 顶部展示用户头像、昵称、手机号 (中间四位用*隐藏)
- 点击昵称可编辑
- 列表项: 宠物档案管理、切换账号、关于
- `ProfileScreen` 在 Step 3 中不再保留“后续完善”占位文案
- 推荐通过 `authProvider` 读取当前用户信息，通过独立的宠物 Provider 管理档案与选择状态

### 4.2 宠物档案管理页面 (`screens/profile/pet_manage_screen.dart`)

```
┌─────────────────────────────────┐
│  ←  宠物档案管理                  │
├─────────────────────────────────┤
│                                 │
│  ┌────────────────────────────┐ │
│  │ 🐱 头像  橘子               │ │
│  │          中华田园猫          │ │
│  │          2023-03-15 出生    │ │
│  └────────────────────────────┘ │
│                                 │
│  ┌────────────────────────────┐ │
│  │ 🐶 头像  旺财               │ │
│  │          柴犬               │ │
│  │          2022-08-20 出生    │ │
│  └────────────────────────────┘ │
│                                 │
│                                 │
│         ┌──────────────┐        │
│         │  ＋ 添加宠物   │        │
│         └──────────────┘        │
└─────────────────────────────────┘
```

- 卡片列表展示所有宠物档案
- 每张卡片显示: 头像(无头像显示默认猫/狗图标)、名字、品种、生日
- 点击卡片进入编辑页面
- 底部有「添加宠物」按钮
- 卡片支持左滑显示删除按钮 (仅 owner)
- 如果当前用户是 `member`，卡片进入详情/只读编辑态，但不显示删除入口

### 4.3 创建/编辑宠物档案页面 (`screens/profile/pet_edit_screen.dart`)

```
┌─────────────────────────────────┐
│  ←  创建宠物档案 / 编辑宠物档案   │
├─────────────────────────────────┤
│                                 │
│        ┌─────────┐              │
│        │  点击上传 │              │
│        │  头像    │              │
│        └─────────┘              │
│                                 │
│  宠物类型                        │
│  ┌─────────┐ ┌─────────┐       │
│  │   🐱 猫  │ │   🐶 狗  │       │
│  └─────────┘ └─────────┘       │
│  (编辑模式下不可修改)              │
│                                 │
│  宠物名字 *                      │
│  ┌─────────────────────────┐    │
│  │                         │    │
│  └─────────────────────────┘    │
│                                 │
│  品种                           │
│  ┌─────────────────────────┐    │
│  │                         │    │
│  └─────────────────────────┘    │
│                                 │
│  生日                           │
│  ┌─────────────────────────┐    │
│  │  点击选择日期             │    │
│  └─────────────────────────┘    │
│                                 │
│  ┌─────────────────────────┐    │
│  │         保  存            │    │
│  └─────────────────────────┘    │
└─────────────────────────────────┘
```

- 宠物类型: 猫/狗 二选一的 `SegmentedButton`
- 编辑模式下宠物类型不可修改 (灰显)
- 头像: 圆形，点击选择图片上传
- 名字: 必填
- 品种: 选填，可以提供常见品种下拉+自定义输入
- 生日: 日期选择器
- 编辑页只允许 `owner` 进入编辑态；若将来复用为详情页，可通过参数切成只读模式

### 4.4 路由建议

推荐在现有 `profile` 分支下补充子路由：

- `/profile` - 我的首页
- `/profile/pets` - 宠物档案管理
- `/profile/pets/new` - 创建宠物档案
- `/profile/pets/:petId/edit` - 编辑宠物档案

这样可以保持底部 Tab 结构不变，同时让返回栈符合移动端直觉。

### 4.5 通用宠物档案选择器组件 (`widgets/pet_selector.dart`)

此组件供「记录」「健康」「时间轴」页面的顶部使用，AI 页暂不接线，但保留 `filter_type` 扩展能力。

**单选模式** (用于记录、健康):
```
┌─────────────────────────────────┐
│  橘子 ▼                         │
│  (点击展开下拉菜单)               │
│  ┌─────────────┐               │
│  │ 🐱 橘子  ✓   │               │
│  │ 🐶 旺财      │               │
│  └─────────────┘               │
└─────────────────────────────────┘
```

**多选模式** (用于时间轴):
```
┌─────────────────────────────────┐
│  全部宠物 ▼                      │
│  (点击展开多选菜单)               │
│  ┌─────────────────┐           │
│  │ ☑ 全部           │           │
│  │ ☑ 🐱 橘子        │           │
│  │ ☑ 🐶 旺财        │           │
│  └─────────────────┘           │
└─────────────────────────────────┘
```

组件参数:
```dart
class PetSelector extends StatelessWidget {
  final bool multiSelect;            // 单选/多选模式
  final List<Pet> pets;              // 宠物列表
  final dynamic selected;            // 单选: Pet?, 多选: List<Pet>
  final Function(dynamic) onChanged; // 选择回调
  final PetType? filterType;         // 可选: 只显示猫或狗
}
```

交互约定：

- 单选模式用于「记录」「健康」，切换后同步更新全局 `selectedPetProvider`
- 多选模式用于「时间轴」，默认“全部宠物”选中
- 当用户首次创建宠物成功后，自动将该宠物设置为当前选中宠物
- 若本地持久化的宠物已不存在，应自动回退到列表第一项或空态

---

## 5. 状态管理 (`providers/pet_provider.dart`)

```dart
// Service Provider
final petServiceProvider = Provider<PetService>((ref) {
  final dio = ref.read(apiClientProvider);
  return PetService(dio);
});

// 宠物列表 Provider
final petListProvider = FutureProvider<PetListResult>((ref) async {
  final service = ref.read(petServiceProvider);
  return await service.getPets(page: 1, pageSize: 20);
});

// 当前选中的宠物 ID，持久化到本地
final selectedPetIdProvider = StateProvider<int?>((ref) => null);

// 对外暴露当前选中的宠物对象
final selectedPetProvider = Provider<Pet?>((ref) {
  final selectedId = ref.watch(selectedPetIdProvider);
  final petList = ref.watch(petListProvider).valueOrNull?.pets ?? const <Pet>[];
  for (final pet in petList) {
    if (pet.id == selectedId) return pet;
  }
  return petList.isEmpty ? null : petList.first;
});

// 时间轴选中的宠物 ID 列表，空数组表示全部
final selectedTimelinePetIdsProvider = StateProvider<List<int>>((ref) => []);
```

**重要**: `selectedPetProvider` 在多个页面间共享。用户在「记录」页切换宠物后，切换到「健康」页时应保持相同选择。

实现建议：

- 本地持久化建议只保存 `pet_id` / `pet_ids`，不要直接持久化完整对象
- 宠物创建成功后，刷新 `petListProvider`，并把新建宠物写入 `selectedPetIdProvider`
- 宠物删除后，如果删除的是当前选中宠物，需要自动切换到剩余列表中的第一只
- 时间轴多选状态单独维护，不要与单选状态共用一个 Provider

### 5.1 前端实现蓝图

推荐职责拆分：

- `models/pet.dart`: `Pet`、`PetListResult`
- `services/pet_service.dart`: `getPets`、`getPetDetail`、`createPet`、`updatePet`、`uploadAvatar`、`deletePet`
- `providers/pet_provider.dart`: 列表、当前选中、时间轴多选、本地恢复
- `screens/profile/profile_screen.dart`: 用户信息与宠物管理入口
- `screens/profile/pet_manage_screen.dart`: 列表、删除、跳转
- `screens/profile/pet_edit_screen.dart`: 创建 / 编辑表单
- `widgets/pet_selector.dart`: 单选 / 多选复用组件

推荐前端实现顺序：

1. 先补 `Pet` 模型与 `PetService`
2. 再完成 `pet_provider.dart` 的列表、选择与本地恢复
3. 接着实现 `ProfileScreen`、`PetManageScreen`、`PetEditScreen`
4. 最后把 `PetSelector` 接到记录、健康、时间轴页面

---

## 6. 常见猫/狗品种预设

### 猫品种

中华田园猫、美国短毛猫、英国短毛猫、布偶猫、暹罗猫、橘猫、奶牛猫、三花猫、狸花猫、波斯猫、缅因猫、斯芬克斯猫、苏格兰折耳猫、俄罗斯蓝猫、其他

### 狗品种

中华田园犬、柴犬、金毛犬、拉布拉多、泰迪/贵宾、柯基、哈士奇、萨摩耶、边牧、博美、比熊、法斗、德牧、雪纳瑞、其他

品种选择建议使用 `Autocomplete + 自由输入` 的方式，预设品种作为推荐，用户也可以手动输入任何品种名称。

---

## 7. 需要创建/修改的文件清单

### 后端

- `backend/app/schemas/pet.py` - 宠物 Schema (完善)
- `backend/app/api/v1/pets.py` - 宠物档案路由 (完善)
- `backend/app/api/v1/router.py` - 注册 pets 路由 (修改)
- `backend/app/services/pet.py` - 宠物领域服务 (新建，推荐)
- `backend/app/services/storage.py` - MinIO 存储服务 (新建，供头像上传使用)
- `backend/app/utils/invite_code.py` - 邀请码生成 (新建)

### 前端

- `frontend/lib/models/pet.dart` - 宠物数据模型 (新建)
- `frontend/lib/services/pet_service.dart` - 宠物 API 服务 (新建)
- `frontend/lib/providers/pet_provider.dart` - 宠物状态管理 (新建)
- `frontend/lib/screens/profile/profile_screen.dart` - 我的页面 (完善)
- `frontend/lib/screens/profile/pet_manage_screen.dart` - 档案管理 (新建)
- `frontend/lib/screens/profile/pet_edit_screen.dart` - 创建/编辑档案 (新建)
- `frontend/lib/widgets/pet_selector.dart` - 宠物选择器组件 (新建)

---

## 8. 验收标准

- [ ] 后端 `POST /api/v1/pets` 创建宠物档案成功，自动生成邀请码
- [ ] 后端 `GET /api/v1/pets` 支持 `page`、`page_size`，并返回 `page`、`page_size`、`total`、`pets`
- [ ] 后端 `GET /api/v1/pets/{id}` 对 owner/member 可见，对非成员返回 `403`
- [ ] 后端 `PUT /api/v1/pets/{id}` 仅 owner 可修改，`pet_type` 不可修改
- [ ] 后端 `POST /api/v1/pets/{id}/avatar` 仅 owner 可上传头像，并返回最新完整对象
- [ ] 后端 `DELETE /api/v1/pets/{id}` 只有 owner 可以删除
- [ ] Flutter「我的」页面展示用户信息
- [ ] Flutter 宠物档案管理页面展示宠物卡片列表
- [ ] Flutter 创建宠物档案页面可以选择猫/狗，输入名字、品种、生日
- [ ] Flutter 编辑页面宠物类型灰显不可修改
- [ ] Flutter 头像上传功能正常
- [ ] Flutter 宠物选择器组件在记录/健康/时间轴页面正确展示
- [ ] 创建第一个宠物档案后，自动设为当前选中的宠物
- [ ] 当前选中的宠物在应用重启后可以恢复
- [ ] 时间轴页可以独立维护多选宠物状态，不影响记录/健康页的单选状态

---

## 9. 联调与验收清单

### 9.1 后端联调顺序

1. 先用 Step 2 的登录接口获取 `access_token`
2. 验证 `POST /api/v1/pets` 创建成功，并自动产生 owner 关系
3. 验证 `GET /api/v1/pets?page=1&page_size=20` 的分页与排序
4. 验证 `GET /api/v1/pets/{pet_id}` 在 owner/member/非成员三种身份下的返回
5. 验证 `PUT /api/v1/pets/{pet_id}`、`POST /api/v1/pets/{pet_id}/avatar`、`DELETE /api/v1/pets/{pet_id}` 的 owner 限制
6. 验证 `invite_code` 对 owner 返回真实值，对 member 返回 `null`

### 9.2 Flutter 联调顺序

1. 登录后进入 `/profile`，确认用户信息正常展示
2. 进入宠物档案管理页，验证空态、分页第一页加载、创建入口
3. 创建第一只宠物后，确认自动设为当前选中宠物，并写入本地持久化
4. 编辑宠物信息并上传头像，返回列表后立即可见
5. 重启应用，确认 `selectedPetProvider` 恢复到上次选择
6. 在「记录」「健康」页面确认单选切换联动
7. 在「时间轴」页面确认多选状态独立维护，且状态结构可直接承接 Step 6 的真实筛选

### 9.3 本步不验收

- 通过邀请码加入宠物档案
- AI 页面接入 `PetSelector`
- 时间轴真实数据筛选接口
