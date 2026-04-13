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

---

## 2. 后端 API 规格

所有 API 需要 `Authorization: Bearer {access_token}` 头。

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
  "created_at": "2024-01-01T00:00:00"
}
```

业务逻辑:
- 验证 name 不为空且长度 <= 50
- pet_type 必须是 "cat" 或 "dog"
- breed 和 birthday 可选
- 自动生成 6 位唯一邀请码 (大写字母+数字组合，排除易混淆字符如 0/O、1/I/L)
- 创建 pet 记录
- 创建 pet_members 记录 (role=owner)
- 驱虫周期默认为 null (用户后续在健康管理中设置)

### 2.2 获取我的所有宠物档案

```
GET /api/v1/pets
```

成功响应 (200):
```json
{
  "pets": [
    {
      "id": 1,
      "name": "橘子",
      "pet_type": "cat",
      "breed": "中华田园猫",
      "birthday": "2023-03-15",
      "avatar_url": "https://...",
      "invite_code": "A3X7K9",
      "internal_deworming_cycle_days": 30,
      "external_deworming_cycle_days": 30,
      "is_owner": true,
      "my_role": "owner",
      "created_at": "2024-01-01T00:00:00"
    },
    {
      "id": 2,
      "name": "旺财",
      "pet_type": "dog",
      "breed": "柴犬",
      "birthday": "2022-08-20",
      "avatar_url": null,
      "invite_code": null,
      "is_owner": false,
      "my_role": "member",
      "created_at": "2024-01-02T00:00:00"
    }
  ]
}
```

业务逻辑:
- 通过 pet_members 表查询当前用户关联的所有宠物档案
- 包含 is_owner 字段标识用户是否为档案创建者
- 包含 `my_role` 字段，便于前端判断当前用户是 `owner` 还是 `member`
- 按创建时间倒序排列（最新创建的在前）
- invite_code 只在 is_owner=true 时返回 (Phase 2 中使用)

### 2.3 获取单个宠物档案详情

```
GET /api/v1/pets/{pet_id}
```

成功响应 (200): 同上单个对象

错误响应 (403): 用户不是该档案的成员

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
- 只有档案成员可以修改 (通过 pet_members 验证)
- pet_type 不允许修改 (猫不能变成狗)
- invite_code 不允许修改
- 部分更新，只更新传入的字段

### 2.5 上传宠物头像

```
POST /api/v1/pets/{pet_id}/avatar
Content-Type: multipart/form-data
```

表单字段:
- `file`: 图片文件 (jpg/png, <= 5MB)

成功响应 (200):
```json
{
  "avatar_url": "http://YOUR_SERVER_IP/media/avatars/pet_1_avatar.jpg"
}
```

业务逻辑:
- 验证文件类型和大小
- 上传到 MinIO avatars bucket
- 更新 pet.avatar_url
- 如果之前有头像，删除旧文件

### 2.6 删除宠物档案

```
DELETE /api/v1/pets/{pet_id}
```

成功响应 (204): No Content

业务逻辑:
- **只有 owner 可以删除**
- 删除档案时级联删除: 所有 pet_members、photos、weights、dewormings、vaccinations
- 删除 MinIO 中对应的照片文件
- 弹窗二次确认由前端处理

---

## 3. 后端实现要点

### 3.1 Pydantic Schema (`app/schemas/pet.py`)

```python
from pydantic import BaseModel, field_validator
from datetime import date, datetime
from app.models.pet import PetType

class PetCreate(BaseModel):
    name: str
    pet_type: PetType
    breed: str | None = None
    birthday: date | None = None

    @field_validator("name")
    @classmethod
    def validate_name(cls, v):
        v = v.strip()
        if not v or len(v) > 50:
            raise ValueError("宠物名字长度为1-50个字符")
        return v

class PetUpdate(BaseModel):
    name: str | None = None
    breed: str | None = None
    birthday: date | None = None

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

    class Config:
        from_attributes = True

class PetListResponse(BaseModel):
    pets: list[PetResponse]
```

### 3.2 邀请码生成

```python
import random
import string

INVITE_CODE_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # 排除 0/O/1/I/L

def generate_invite_code(length: int = 6) -> str:
    return ''.join(random.choices(INVITE_CODE_CHARS, k=length))
```

生成后需检查数据库唯一性，冲突则重新生成。

### 3.3 权限检查辅助函数

```python
async def get_pet_with_permission(
    pet_id: int, user_id: int, db: AsyncSession, require_owner: bool = False
) -> Pet:
    """获取宠物档案，同时验证用户权限"""
    pet = await db.get(Pet, pet_id)
    if not pet:
        raise HTTPException(status_code=404, detail="宠物档案不存在")

    member = await db.execute(
        select(PetMember).where(
            PetMember.pet_id == pet_id,
            PetMember.user_id == user_id,
        )
    )
    member = member.scalar_one_or_none()
    if not member:
        raise HTTPException(status_code=403, detail="无权访问该宠物档案")

    if require_owner and member.role != MemberRole.OWNER:
        raise HTTPException(status_code=403, detail="只有档案创建者才能执行此操作")

    return pet
```

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

- 宠物类型: 猫/狗 二选一的 SegmentedButton
- 编辑模式下宠物类型不可修改 (灰显)
- 头像: 圆形，点击选择图片上传
- 名字: 必填
- 品种: 选填，可以提供常见品种下拉+自定义输入
- 生日: 日期选择器

### 4.4 通用宠物档案选择器组件 (`widgets/pet_selector.dart`)

此组件供「记录」「健康」「时间轴」「AI」页面的顶部使用。

**单选模式** (用于记录、健康、AI):
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
  final bool multiSelect;           // 单选/多选模式
  final List<Pet> pets;             // 宠物列表
  final dynamic selected;           // 单选: Pet?, 多选: List<Pet>
  final Function(dynamic) onChanged; // 选择回调
  final PetType? filterType;        // 可选: 只显示猫或狗 (AI猫忍痛识别用)
}
```

---

## 5. 状态管理 (`providers/pet_provider.dart`)

```dart
// 宠物列表 Provider
final petListProvider = FutureProvider<List<Pet>>((ref) async {
  final apiClient = ref.read(apiClientProvider);
  return await PetService(apiClient).getPets();
});

// 当前选中的宠物 Provider (全局共享)
final selectedPetProvider = StateProvider<Pet?>((ref) => null);

// 时间轴选中的宠物列表 Provider
final selectedTimelinePetsProvider = StateProvider<List<Pet>>((ref) => []);
```

**重要**: `selectedPetProvider` 在多个页面间共享。用户在「记录」页切换宠物后，切换到「健康」页时应保持相同选择。

---

## 6. 常见猫/狗品种预设

### 猫品种
中华田园猫、英短蓝猫、美短虎斑、布偶猫、暹罗猫、橘猫、奶牛猫、三花猫、狸花猫、波斯猫、缅因猫、斯芬克斯猫、苏格兰折耳猫、俄罗斯蓝猫、其他

### 狗品种
中华田园犬、柴犬、金毛寻回犬、拉布拉多、泰迪/贵宾、柯基、哈士奇、萨摩耶、边牧、博美、比熊、法斗、德牧、雪纳瑞、其他

品种选择建议使用 Autocomplete + 自由输入的方式，预设品种作为推荐，用户也可以手动输入任何品种名称。

---

## 7. 需要创建/修改的文件清单

### 后端
- `backend/app/schemas/pet.py` - 宠物 Schema (新建)
- `backend/app/api/v1/pets.py` - 宠物档案路由 (新建)
- `backend/app/api/v1/router.py` - 注册 pets 路由 (修改)
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
- [ ] 后端 `GET /api/v1/pets` 返回当前用户的所有宠物档案
- [ ] 后端 `PUT /api/v1/pets/{id}` 更新档案信息，pet_type 不可修改
- [ ] 后端 `POST /api/v1/pets/{id}/avatar` 上传头像到 MinIO
- [ ] 后端 `DELETE /api/v1/pets/{id}` 只有 owner 可以删除
- [ ] Flutter「我的」页面展示用户信息
- [ ] Flutter 宠物档案管理页面展示宠物卡片列表
- [ ] Flutter 创建宠物档案页面可以选择猫/狗，输入名字、品种、生日
- [ ] Flutter 编辑页面宠物类型灰显不可修改
- [ ] Flutter 头像上传功能正常
- [ ] Flutter 宠物选择器组件在记录/健康页面正确展示
- [ ] 创建第一个宠物档案后，自动设为当前选中的宠物
