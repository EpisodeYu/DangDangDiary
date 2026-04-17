# Step 5: 健康管理 (体重/日常/驱虫/疫苗)

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL 技术栈。本步骤实现健康管理模块，包括体重记录、日常护理、驱虫管理和疫苗管理四个子功能。

**前置依赖**: Step 3 已完成 (宠物档案管理)，宠物选择器组件可用。

---

## 本步骤目标

1. 后端实现体重 CRUD API + 历史列表查询
2. 后端实现驱虫 CRUD API + 三类驱虫周期管理 + 倒计时计算
3. 后端实现疫苗 CRUD API + 疫苗类型预设
4. 后端实现日常 CRUD API + 三类日常项目（洗澡/剪指甲/梳毛）周期与提醒管理 + 倒计时计算
5. Flutter 实现「健康」页面，包含四个子 Tab（体重/日常/驱虫/疫苗）、动态 FAB 和完整交互

---

## 1. 页面结构概览

```
┌──────────────────────────────────────────┐
│  橘子 ▼         体重 | 日常 | 驱虫 | 疫苗 │
├──────────────────────────────────────────┤
│                                          │
│         (子页面内容区域)                  │
│     根据右上角 Tab 切换展示               │
│                                          │
│                                          │
│                                   ┌────┐ │
│                                   │ ＋ │ │  ← 浮动记录按钮
│                                   └────┘ │
├──────────────────────────────────────────┤
│  记录  │  健康  │ 时间轴 │  AI  │ 我的   │
└──────────────────────────────────────────┘
```

- 顶部左侧: 宠物选择器 (单选模式)
- 顶部右侧: 体重/日常/驱虫/疫苗四个 Tab 按钮（顺序固定为：体重 → 日常 → 驱虫 → 疫苗）
- 中间: 根据 Tab 展示对应内容
- 右下角: 浮动的「+」记录按钮，点击进入对应的记录页面

---

## 2. 后端 API 规格

所有 API 需要 `Authorization: Bearer {access_token}` 头。

权限说明:
- 共享档案中，`owner` 和 `member` 都可以新增、编辑、删除体重/驱虫/疫苗记录
- `PUT /api/v1/pets/{pet_id}/deworming-cycle` 允许 `owner` 和 `member` 修改
- 普通记录的编辑/删除不区分创建人，只要当前用户可以访问该宠物档案即可操作

驱虫说明:
- 猫和狗都统一支持三类驱虫: `internal` (内驱)、`external` (外驱)、`combined` (内外同驱)
- 三类驱虫分别拥有各自的最近记录时间、周期配置和状态
- 驱虫提醒不是默认全开，只有用户为某一类驱虫勾选提醒后，才按该类周期计算和展示状态

日常说明:
- 猫和狗都统一支持三类日常: `bath` (洗澡)、`nail_trim` (剪指甲)、`grooming` (梳毛)
- 三类日常分别拥有各自的最近记录时间、周期配置和状态
- 日常提醒同样不是默认全开，只有用户为某一类日常勾选提醒后，才按该类周期计算和展示状态
- 日常模块的字段/接口/状态计算逻辑与驱虫完全对齐，仅字段命名不同（`dewormed_at` → `performed_at`，`deworming_type` → `routine_type`）

### 2.1 体重模块

#### 记录体重

```
POST /api/v1/pets/{pet_id}/weights
Content-Type: application/json
```

请求体:
```json
{
  "weight_kg": 4.5,
  "recorded_at": "2024-01-15"
}
```

成功响应 (201):
```json
{
  "id": 1,
  "pet_id": 1,
  "user_id": 1,
  "weight_kg": 4.5,
  "recorded_at": "2024-01-15",
  "created_at": "2024-01-20T10:30:00"
}
```

验证规则:
- `weight_kg`: 大于 0，最多两位小数，最大 200kg
- `recorded_at`: 有效日期，不能是未来日期

#### 获取体重历史

```
GET /api/v1/pets/{pet_id}/weights?page=1&page_size=50
```

成功响应 (200):
```json
{
  "weights": [
    {
      "id": 1,
      "pet_id": 1,
      "user_id": 1,
      "weight_kg": 4.5,
      "recorded_at": "2024-01-15",
      "created_at": "2024-01-20T10:30:00"
    }
  ],
  "total": 30,
  "page": 1,
  "page_size": 50,
  "total_pages": 1
}
```

排序: `recorded_at desc, created_at desc, id desc`

#### 更新体重记录

```
PUT /api/v1/weights/{weight_id}
Content-Type: application/json
```

请求体:
```json
{
  "weight_kg": 4.8,
  "recorded_at": "2024-01-16"
}
```

成功响应 (200): 返回更新后的完整对象，字段与“记录体重”一致

#### 删除体重记录

```
DELETE /api/v1/weights/{weight_id}
```

成功响应 (204)

---

### 2.2 驱虫模块

#### 记录驱虫

```
POST /api/v1/pets/{pet_id}/dewormings
Content-Type: application/json
```

请求体:
```json
{
  "deworming_type": "combined",
  "dewormed_at": "2024-01-15"
}
```

成功响应 (201):
```json
{
  "id": 1,
  "pet_id": 1,
  "user_id": 1,
  "deworming_type": "combined",
  "dewormed_at": "2024-01-15",
  "created_at": "2024-01-20T10:30:00"
}
```

验证规则:
- `deworming_type`: 必须是 `internal` (内驱)、`external` (外驱) 或 `combined` (内外同驱)
- `dewormed_at`: 有效日期，不能是未来日期

#### 获取驱虫历史

```
GET /api/v1/pets/{pet_id}/dewormings?page=1&page_size=50
```

成功响应 (200):
```json
{
  "dewormings": [
    {
      "id": 1,
      "pet_id": 1,
      "user_id": 1,
      "deworming_type": "internal",
      "dewormed_at": "2024-01-15",
      "created_at": "2024-01-20T10:30:00"
    },
    {
      "id": 2,
      "pet_id": 1,
      "user_id": 1,
      "deworming_type": "combined",
      "dewormed_at": "2024-01-10",
      "created_at": "2024-01-20T10:31:00"
    }
  ],
  "total": 20,
  "page": 1,
  "page_size": 50,
  "total_pages": 1
}
```

排序: `dewormed_at desc, created_at desc, id desc`

#### 更新驱虫记录

```
PUT /api/v1/dewormings/{deworming_id}
Content-Type: application/json
```

请求体:
```json
{
  "deworming_type": "external",
  "dewormed_at": "2024-01-16"
}
```

成功响应 (200): 返回更新后的完整对象，字段与“记录驱虫”一致

#### 删除驱虫记录

```
DELETE /api/v1/dewormings/{deworming_id}
```

成功响应 (204)

#### 设置驱虫周期与提醒开关

```
PUT /api/v1/pets/{pet_id}/deworming-cycle
Content-Type: application/json
```

请求体:
```json
{
  "internal_cycle_days": 30,
  "external_cycle_days": 30,
  "combined_cycle_days": 90,
  "internal_reminder_enabled": true,
  "external_reminder_enabled": false,
  "combined_reminder_enabled": true
}
```

成功响应 (200):
```json
{
  "internal_cycle_days": 30,
  "external_cycle_days": 30,
  "combined_cycle_days": 90,
  "internal_reminder_enabled": true,
  "external_reminder_enabled": false,
  "combined_reminder_enabled": true
}
```

验证规则:
- 三个周期字段都可选，只更新传入字段
- 周期范围: `1-365`
- 三个提醒布尔字段都可选
- 取消某类提醒后，该类历史记录仍保留，且允许继续录入该类驱虫记录

#### 获取驱虫状态 (倒计时)

```
GET /api/v1/pets/{pet_id}/deworming-status
```

成功响应 (200):
```json
{
  "internal": {
    "reminder_enabled": true,
    "last_dewormed_at": "2024-01-01",
    "cycle_days": 30,
    "next_due_at": "2024-01-31",
    "days_remaining": 11,
    "is_overdue": false
  },
  "external": {
    "reminder_enabled": false,
    "last_dewormed_at": "2023-12-15",
    "cycle_days": 30,
    "next_due_at": null,
    "days_remaining": null,
    "is_overdue": null
  },
  "combined": {
    "reminder_enabled": true,
    "last_dewormed_at": "2023-11-01",
    "cycle_days": 90,
    "next_due_at": "2024-01-30",
    "days_remaining": -2,
    "is_overdue": true
  }
}
```

计算逻辑:
- `next_due_at = 最后一次驱虫日期 + 周期天数`
- `days_remaining = next_due_at - 今天`，正数表示剩余天数，负数表示已过期天数
- `is_overdue = days_remaining < 0`
- 若某类驱虫未勾选提醒，则该类返回 `reminder_enabled=false`，`next_due_at`、`days_remaining`、`is_overdue` 返回 `null`，但 `last_dewormed_at` / `cycle_days` 仍按现状返回（便于前端在重新打开提醒时直接展示）
- 若已勾选提醒，但尚未设置周期或没有对应记录，则 `last_dewormed_at` / `cycle_days` 按现状返回，其余倒计时字段返回 `null`

---

### 2.3 疫苗模块

#### 记录疫苗

```
POST /api/v1/pets/{pet_id}/vaccinations
Content-Type: application/json
```

请求体:
```json
{
  "vaccine_type": "猫三联疫苗",
  "vaccinated_at": "2024-01-15"
}
```

成功响应 (201):
```json
{
  "id": 1,
  "pet_id": 1,
  "user_id": 1,
  "vaccine_type": "猫三联疫苗",
  "vaccinated_at": "2024-01-15",
  "created_at": "2024-01-20T10:30:00"
}
```

验证规则:
- `vaccine_type`: 不为空，长度 `<= 100`
- `vaccinated_at`: 有效日期，不能是未来日期

#### 获取疫苗历史

```
GET /api/v1/pets/{pet_id}/vaccinations?page=1&page_size=50
```

成功响应 (200):
```json
{
  "vaccinations": [
    {
      "id": 1,
      "pet_id": 1,
      "user_id": 1,
      "vaccine_type": "猫三联疫苗",
      "vaccinated_at": "2024-01-15",
      "created_at": "2024-01-20T10:30:00"
    }
  ],
  "total": 10,
  "page": 1,
  "page_size": 50,
  "total_pages": 1
}
```

排序: `vaccinated_at desc, created_at desc, id desc`

#### 更新疫苗记录

```
PUT /api/v1/vaccinations/{vaccination_id}
Content-Type: application/json
```

请求体:
```json
{
  "vaccine_type": "狂犬病疫苗",
  "vaccinated_at": "2024-01-20"
}
```

成功响应 (200): 返回更新后的完整对象，字段与“记录疫苗”一致

#### 删除疫苗记录

```
DELETE /api/v1/vaccinations/{vaccination_id}
```

成功响应 (204)

#### 获取疫苗类型预设

```
GET /api/v1/vaccine-types?pet_type=cat
```

成功响应 (200):
```json
{
  "preset_types": [
    "猫三联疫苗",
    "狂犬病疫苗",
    "猫四联疫苗",
    "猫白血病疫苗",
    "猫五联疫苗",
    "猫传染性腹膜炎疫苗"
  ],
  "pet_type": "cat"
}
```

此 API 不需要数据库，直接返回 `app/services/health.py` 中硬编码的 `VACCINE_PRESETS`（按"国内常见度从高到低"排序，顺序须与响应保持一致）:
- 猫 (6 项): 猫三联疫苗、狂犬病疫苗、猫四联疫苗、猫白血病疫苗、猫五联疫苗、猫传染性腹膜炎疫苗
- 狗 (8 项): 狂犬病疫苗、犬八联疫苗、犬六联疫苗、犬四联疫苗、犬二联疫苗、犬窝咳疫苗、莱姆病疫苗、犬流感疫苗

`pet_type` 仅接受 `cat` / `dog`，否则返回 `400 INVALID_PET_TYPE`。

注：列表只用作前端的快选标签建议，后端不做白名单校验，用户仍可自定义输入任意名称（满足 1-100 字符即可）。修改预设时请同步本节及 §5。

---

### 2.4 日常模块

日常模块的接口与驱虫完全对齐，仅将 `dewormings/deworming_type/dewormed_at` 替换为 `routines/routine_type/performed_at`。

#### 记录日常

```
POST /api/v1/pets/{pet_id}/routines
Content-Type: application/json
```

请求体:
```json
{
  "routine_type": "bath",
  "performed_at": "2024-01-15"
}
```

成功响应 (201):
```json
{
  "id": 1,
  "pet_id": 1,
  "user_id": 1,
  "routine_type": "bath",
  "performed_at": "2024-01-15",
  "created_at": "2024-01-20T10:30:00"
}
```

验证规则:
- `routine_type`: 必须是 `bath` (洗澡)、`nail_trim` (剪指甲) 或 `grooming` (梳毛)
- `performed_at`: 有效日期，不能是未来日期

#### 获取日常历史

```
GET /api/v1/pets/{pet_id}/routines?page=1&page_size=50
```

成功响应 (200):
```json
{
  "routines": [
    {
      "id": 1,
      "pet_id": 1,
      "user_id": 1,
      "routine_type": "bath",
      "performed_at": "2024-01-15",
      "created_at": "2024-01-20T10:30:00"
    }
  ],
  "total": 20,
  "page": 1,
  "page_size": 50,
  "total_pages": 1
}
```

排序: `performed_at desc, created_at desc, id desc`

#### 更新日常记录

```
PUT /api/v1/routines/{routine_id}
Content-Type: application/json
```

请求体:
```json
{
  "routine_type": "nail_trim",
  "performed_at": "2024-01-16"
}
```

成功响应 (200): 返回更新后的完整对象，字段与"记录日常"一致

#### 删除日常记录

```
DELETE /api/v1/routines/{routine_id}
```

成功响应 (204)

#### 设置日常周期与提醒开关

```
PUT /api/v1/pets/{pet_id}/routine-cycle
Content-Type: application/json
```

请求体:
```json
{
  "bath_cycle_days": 14,
  "nail_trim_cycle_days": 30,
  "grooming_cycle_days": 7,
  "bath_reminder_enabled": true,
  "nail_trim_reminder_enabled": false,
  "grooming_reminder_enabled": true
}
```

成功响应 (200):
```json
{
  "bath_cycle_days": 14,
  "nail_trim_cycle_days": 30,
  "grooming_cycle_days": 7,
  "bath_reminder_enabled": true,
  "nail_trim_reminder_enabled": false,
  "grooming_reminder_enabled": true
}
```

验证规则:
- 三个周期字段都可选，只更新传入字段
- 周期范围: `1-365`
- 三个提醒布尔字段都可选
- 取消某类提醒后，该类历史记录仍保留，且允许继续录入该类日常记录

#### 获取日常状态 (倒计时)

```
GET /api/v1/pets/{pet_id}/routine-status
```

成功响应 (200):
```json
{
  "bath": {
    "reminder_enabled": true,
    "last_performed_at": "2024-01-01",
    "cycle_days": 14,
    "next_due_at": "2024-01-15",
    "days_remaining": 5,
    "is_overdue": false
  },
  "nail_trim": {
    "reminder_enabled": false,
    "last_performed_at": "2023-12-15",
    "cycle_days": 30,
    "next_due_at": null,
    "days_remaining": null,
    "is_overdue": null
  },
  "grooming": {
    "reminder_enabled": true,
    "last_performed_at": null,
    "cycle_days": 7,
    "next_due_at": null,
    "days_remaining": null,
    "is_overdue": null
  }
}
```

计算逻辑完全对齐驱虫状态：
- `next_due_at = 最后一次记录日期 + 周期天数`
- `days_remaining = next_due_at - 今天`，正数表示剩余天数，负数表示已过期天数
- `is_overdue = days_remaining < 0`
- 未勾选提醒时 `reminder_enabled=false`，倒计时字段返回 `null`，但 `last_performed_at` / `cycle_days` 保持原值
- 已勾选提醒但缺少周期或记录时，其余倒计时字段返回 `null`

---

## 3. 后端实现要点

### 3.1 Pydantic Schema (`app/schemas/health.py`)

> 实现要点：`*Update` 直接继承同名 `*Create`，复用全部校验逻辑；列表响应统一带 `total / page / page_size / total_pages` 四个分页字段。

```python
from datetime import date, datetime
from decimal import Decimal

from pydantic import BaseModel, field_validator

from app.models.deworming import DewormingType


# ---------------- Weight ----------------
class WeightCreate(BaseModel):
    weight_kg: Decimal
    recorded_at: date

    @field_validator("weight_kg")
    @classmethod
    def validate_weight(cls, v: Decimal) -> Decimal:
        if v <= 0 or v > Decimal("200"):
            raise ValueError("体重必须在 0-200kg 之间")
        if v.as_tuple().exponent < -2:
            raise ValueError("体重最多保留两位小数")
        return v

    @field_validator("recorded_at")
    @classmethod
    def validate_date(cls, v: date) -> date:
        if v > date.today():
            raise ValueError("记录日期不能是未来日期")
        return v


class WeightUpdate(WeightCreate):
    pass


class WeightResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    weight_kg: Decimal
    recorded_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class WeightListResponse(BaseModel):
    weights: list[WeightResponse]
    total: int
    page: int
    page_size: int
    total_pages: int


# ---------------- Deworming ----------------
class DewormingCreate(BaseModel):
    deworming_type: DewormingType
    dewormed_at: date

    @field_validator("dewormed_at")
    @classmethod
    def validate_date(cls, v: date) -> date:
        if v > date.today():
            raise ValueError("驱虫日期不能是未来日期")
        return v


class DewormingUpdate(DewormingCreate):
    pass


class DewormingResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    deworming_type: DewormingType
    dewormed_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class DewormingListResponse(BaseModel):
    dewormings: list[DewormingResponse]
    total: int
    page: int
    page_size: int
    total_pages: int


class DewormingCycleUpdate(BaseModel):
    internal_cycle_days: int | None = None
    external_cycle_days: int | None = None
    combined_cycle_days: int | None = None
    internal_reminder_enabled: bool | None = None
    external_reminder_enabled: bool | None = None
    combined_reminder_enabled: bool | None = None

    @field_validator(
        "internal_cycle_days",
        "external_cycle_days",
        "combined_cycle_days",
    )
    @classmethod
    def validate_cycle(cls, v: int | None) -> int | None:
        if v is not None and (v < 1 or v > 365):
            raise ValueError("驱虫周期必须在 1-365 天之间")
        return v


class DewormingCycleResponse(BaseModel):
    internal_cycle_days: int | None
    external_cycle_days: int | None
    combined_cycle_days: int | None
    internal_reminder_enabled: bool
    external_reminder_enabled: bool
    combined_reminder_enabled: bool


class DewormingStatusItem(BaseModel):
    reminder_enabled: bool
    last_dewormed_at: date | None
    cycle_days: int | None
    next_due_at: date | None
    days_remaining: int | None
    is_overdue: bool | None


class DewormingStatusResponse(BaseModel):
    internal: DewormingStatusItem
    external: DewormingStatusItem
    combined: DewormingStatusItem


# ---------------- Vaccination ----------------
class VaccinationCreate(BaseModel):
    vaccine_type: str
    vaccinated_at: date

    @field_validator("vaccine_type")
    @classmethod
    def validate_type(cls, v: str) -> str:
        v = v.strip()
        if not v or len(v) > 100:
            raise ValueError("疫苗类型长度为1-100个字符")
        return v

    @field_validator("vaccinated_at")
    @classmethod
    def validate_date(cls, v: date) -> date:
        if v > date.today():
            raise ValueError("接种日期不能是未来日期")
        return v


class VaccinationUpdate(VaccinationCreate):
    pass


class VaccinationResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    vaccine_type: str
    vaccinated_at: date
    created_at: datetime

    model_config = {"from_attributes": True}


class VaccinationListResponse(BaseModel):
    vaccinations: list[VaccinationResponse]
    total: int
    page: int
    page_size: int
    total_pages: int


class VaccineTypePresetResponse(BaseModel):
    preset_types: list[str]
    pet_type: str
```

### 3.2 业务服务（`app/services/health.py`）

所有写操作进入服务前，先调用 `app.services.pet.get_pet_membership(pet_id, user_id, db)` 校验：当前用户是否对该宠物存在 `owner` 或 `member` 角色，不存在则抛 `403`。该函数返回 `(pet, member_role)`，可以复用 pet 对象。

驱虫周期更新使用 `model_dump(exclude_unset=True)` 仅写入显式传入的字段，并通过 `field_map` 把 schema 字段名映射到 ORM 列名（`internal_cycle_days → internal_deworming_cycle_days` 等）。

驱虫状态计算逻辑：

```python
from datetime import date, timedelta

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.deworming import Deworming, DewormingType
from app.schemas.health import (
    DewormingStatusItem,
    DewormingStatusResponse,
)
from app.services.pet import get_pet_membership


async def get_deworming_status(
    db: AsyncSession,
    pet_id: int,
    user_id: int,
) -> DewormingStatusResponse:
    pet, _ = await get_pet_membership(pet_id, user_id, db)

    internal = await _calc_status(
        db, pet_id, DewormingType.INTERNAL,
        pet.internal_deworming_cycle_days, pet.internal_reminder_enabled,
    )
    external = await _calc_status(
        db, pet_id, DewormingType.EXTERNAL,
        pet.external_deworming_cycle_days, pet.external_reminder_enabled,
    )
    combined = await _calc_status(
        db, pet_id, DewormingType.COMBINED,
        pet.combined_deworming_cycle_days, pet.combined_reminder_enabled,
    )
    return DewormingStatusResponse(
        internal=internal,
        external=external,
        combined=combined,
    )


async def _calc_status(
    db: AsyncSession,
    pet_id: int,
    deworming_type: DewormingType,
    cycle_days: int | None,
    reminder_enabled: bool,
) -> DewormingStatusItem:
    result = await db.execute(
        select(Deworming)
        .where(
            Deworming.pet_id == pet_id,
            Deworming.deworming_type == deworming_type,
        )
        # id 作为 tiebreaker，避免同一天多条记录顺序不稳定
        .order_by(Deworming.dewormed_at.desc(), Deworming.id.desc())
        .limit(1)
    )
    last = result.scalar_one_or_none()
    last_date = last.dewormed_at if last else None

    if not reminder_enabled:
        return DewormingStatusItem(
            reminder_enabled=False,
            last_dewormed_at=last_date,
            cycle_days=cycle_days,
            next_due_at=None,
            days_remaining=None,
            is_overdue=None,
        )

    if last_date is None or not cycle_days:
        return DewormingStatusItem(
            reminder_enabled=True,
            last_dewormed_at=last_date,
            cycle_days=cycle_days,
            next_due_at=None,
            days_remaining=None,
            is_overdue=None,
        )

    next_due = last_date + timedelta(days=cycle_days)
    remaining = (next_due - date.today()).days
    return DewormingStatusItem(
        reminder_enabled=True,
        last_dewormed_at=last_date,
        cycle_days=cycle_days,
        next_due_at=next_due,
        days_remaining=remaining,
        is_overdue=remaining < 0,
    )
```

### 3.3 路由注册

新增的 `health.router`（`tags=["health"]`，无路径前缀，内部直接使用 `/pets/{pet_id}/...`、`/weights/{id}` 等绝对路径）需要在 `app/api/v1/router.py` 中追加：

```python
from app.api.v1 import auth, pets, photos, health

api_v1_router.include_router(health.router)
```

### 3.4 Pet 模型与迁移

`Pet` 模型新增以下字段（与原有 `internal_deworming_cycle_days / external_deworming_cycle_days` 一起组成完整三类配置）：

- `combined_deworming_cycle_days: Integer NULL`
- `internal_reminder_enabled: Boolean NOT NULL DEFAULT false`
- `external_reminder_enabled: Boolean NOT NULL DEFAULT false`
- `combined_reminder_enabled: Boolean NOT NULL DEFAULT false`

对应迁移 `alembic/versions/a1b2c3d4e5f6_step5_health_fields.py`：
- 通过 `ALTER TYPE dewormingtype ADD VALUE IF NOT EXISTS 'COMBINED'` 扩展 Postgres 枚举（注意 enum 大小写需与 `DewormingType` 成员名一致）
- 三个布尔列先用 `server_default=sa.false()` 回填历史数据，再 `alter_column(... server_default=None)` 让应用层接管默认值

`PetResponse` 同步暴露上述六个字段，前端可在初始化驱虫周期页面时直接读取。

日常模块后续再新增以下字段和迁移：

- `bath_cycle_days: Integer NULL`
- `nail_trim_cycle_days: Integer NULL`
- `grooming_cycle_days: Integer NULL`
- `bath_reminder_enabled: Boolean NOT NULL DEFAULT false`
- `nail_trim_reminder_enabled: Boolean NOT NULL DEFAULT false`
- `grooming_reminder_enabled: Boolean NOT NULL DEFAULT false`

对应迁移 `alembic/versions/b2c3d4e5f6a7_step5_routine.py`：
- 新建 `routines` 表 + `routinetype` PostgreSQL 枚举（`BATH / NAIL_TRIM / GROOMING`）
- 在 `pets` 上新增上述 6 列；布尔列同样使用 `server_default=sa.false()` 回填再取消默认值

`PetResponse` 同步暴露日常模块的 6 个字段，前端日常周期页可直接读取并作为初始值。

---

## 4. Flutter 页面设计

### 4.1 健康页面主框架 (`screens/health/health_screen.dart`)

顶部使用宠物选择器 (单选) + 右侧 Tab 切换 (体重/日常/驱虫/疫苗，顺序固定)。
使用 `TabBarView` 实现四个子页面的切换。
页面右下角使用动态 FAB，根据当前 Tab 跳转到对应的独立记录页面。

### 4.2 体重 Tab (`screens/health/weight_tab.dart`)

```
┌─────────────────────────────────┐
│                                 │
│  最新体重: 4.8 kg               │
│  记录日期: 2024-01-15            │
│                                 │
│  ── 体重记录 ──────────────────  │
│                                 │
│  📅 2024-01-15                  │
│     4.8 kg                      │
│  ─────────────────              │
│  📅 2024-01-01                  │
│     4.5 kg                      │
│  ─────────────────              │
│  📅 2023-12-15                  │
│     4.3 kg                      │
│                                 │
│                          ┌────┐ │
│                          │ ＋ │ │
│                          └────┘ │
└─────────────────────────────────┘
```

- 顶部展示最新体重和日期
- 下方按时间轴列表展示历史体重记录
- 每条记录左滑可编辑/删除
- 右下角浮动「+」按钮进入体重记录页面

### 4.3 体重记录页面 (独立新页面)

```
┌─────────────────────────────────┐
│  ←  记录体重                     │
├─────────────────────────────────┤
│                                 │
│  体重 (kg)                      │
│  ┌─────────────────────────┐    │
│  │  4.8                    │    │
│  └─────────────────────────┘    │
│  (数字键盘，支持小数点)            │
│                                 │
│  记录日期                        │
│  ┌─────────────────────────┐    │
│  │  2024-01-15    📅        │    │
│  └─────────────────────────┘    │
│  (默认今天，可修改)               │
│                                 │
│  ┌─────────────────────────┐    │
│  │         确认记录          │    │
│  └─────────────────────────┘    │
└─────────────────────────────────┘
```

### 4.4 驱虫 Tab (`screens/health/deworming_tab.dart`)

```
┌─────────────────────────────────┐
│                                 │
│  ☑ 内驱      距离下次驱虫 15 天   │
│  ☐ 外驱      已关闭提醒           │
│  ☑ 内外同驱  已过期 3 天         │
│  [设置周期]                      │
│                                 │
│  ── 驱虫记录 ──────────────────  │
│                                 │
│  📅 2024-01-15                  │
│     内外同驱                    │
│  ─────────────────              │
│  📅 2024-01-10                  │
│     外驱                        │
│  ─────────────────              │
│  📅 2023-12-15                  │
│     内驱                        │
│                                 │
│                          ┌────┐ │
│                          │ ＋ │ │
│                          └────┘ │
└─────────────────────────────────┘
```

- 顶部卡片展示驱虫倒计时状态
  - 分为 `内驱`、`外驱`、`内外同驱` 三个独立项目
  - 每个项目左侧都有提醒勾选框
  - 正常: 黑色文字 "距离下次驱虫 XX 天"
  - 过期: 红色文字 "距离驱虫日期已过 XX 天"
  - 未勾选提醒: 提示 "已关闭提醒"
  - 已勾选但未设置周期或无记录: 提示 "请先设置驱虫周期" 或 "请先记录驱虫日期"
- 点击“设置周期”进入独立的驱虫周期设置页面
- 下方展示驱虫历史记录，明确标注 `内驱` / `外驱` / `内外同驱`
- 右下角浮动「+」按钮进入驱虫记录页面

### 4.5 驱虫记录页面

```
┌─────────────────────────────────┐
│  ←  记录驱虫                     │
├─────────────────────────────────┤
│                                 │
│  驱虫类型                        │
│  ┌──────┐ ┌──────┐ ┌────────┐  │
│  │ 内驱 │ │ 外驱 │ │ 内外同驱 │  │
│  └──────┘ └──────┘ └────────┘  │
│  (ChoiceChip 三选一)             │
│                                 │
│  驱虫日期                        │
│  ┌─────────────────────────┐    │
│  │  2024-01-15    📅        │    │
│  └─────────────────────────┘    │
│  (默认今天，可修改)               │
│                                 │
│  ┌─────────────────────────┐    │
│  │         确认记录          │    │
│  └─────────────────────────┘    │
└─────────────────────────────────┘
```

### 4.6 驱虫周期设置页面

```
┌─────────────────────────────────┐
│  ←  设置驱虫周期与提醒            │
├─────────────────────────────────┤
│  内驱                       [●━] │
│  周期： [ 30 ] 天 (1-365)        │
│                                 │
│  外驱                       [●━] │
│  周期： [ 30 ] 天 (1-365)        │
│                                 │
│  内外同驱                   [━○] │
│  周期： [ 90 ] 天 (1-365)        │
│                                 │
│  ┌─────────────────────────┐    │
│  │         保存设置          │    │
│  └─────────────────────────┘    │
└─────────────────────────────────┘
```

- 用于统一编辑三类驱虫的周期值
- 提醒开关使用 `Switch`（不是 Checkbox），与驱虫 Tab 顶部的勾选框双向同步
- 周期输入框默认值：内驱 / 外驱 30，内外同驱 90；保存前在前端额外做 1-365 的范围校验，防止误输入
- 表单仅传入用户实际填写或调整过的字段；后端只更新显式传入的字段（`exclude_unset=True`），未填写的字段保持原值
- 保存成功后需 `invalidate(dewormingStatusProvider(petId))` 并刷新 `petListProvider`，以便驱虫 Tab 的勾选框、倒计时、本页初始值都能拿到最新数据

### 4.7 疫苗 Tab (`screens/health/vaccination_tab.dart`)

```
┌─────────────────────────────────┐
│                                 │
│  ── 疫苗记录 ──────────────────  │
│                                 │
│  📅 2024-01-15                  │
│     猫三联疫苗                  │
│  ─────────────────              │
│  📅 2023-07-20                  │
│     狂犬病疫苗                  │
│  ─────────────────              │
│  📅 2023-01-10                  │
│     猫三联疫苗                  │
│                                 │
│                                 │
│                          ┌────┐ │
│                          │ ＋ │ │
│                          └────┘ │
└─────────────────────────────────┘
```

- 按时间轴展示疫苗接种历史
- 每条记录标注疫苗类型
- 记录支持左滑编辑/删除

### 4.8 疫苗记录页面

```
┌─────────────────────────────────┐
│  ←  记录疫苗                     │
├─────────────────────────────────┤
│                                 │
│  疫苗类型                        │
│  ┌─────────────────────────┐    │
│  │  请选择或输入疫苗类型      │    │
│  └─────────────────────────┘    │
│                                 │
│  ┌────────┐ ┌────────┐ ┌────────┐ │
│  │猫三联疫苗│ │狂犬病疫苗│ │猫四联疫苗│  ← 预设快选 │
│  └────────┘ └────────┘ └────────┘ │
│  (按宠物类型展示完整预设，可横向换行) │
│  (点击预设标签自动填入输入框)      │
│                                 │
│  接种日期                        │
│  ┌─────────────────────────┐    │
│  │  2024-01-15    📅        │    │
│  └─────────────────────────┘    │
│  (默认今天，可修改)               │
│                                 │
│  ┌─────────────────────────┐    │
│  │         确认记录          │    │
│  └─────────────────────────┘    │
└─────────────────────────────────┘
```

- 疫苗类型: 输入框 + 预设标签快选
- 预设标签根据当前宠物类型 (猫/狗) 动态显示
- 点击预设标签自动填入输入框
- 也支持手动输入自定义疫苗名称

### 4.9 日常 Tab (`screens/health/routine_tab.dart`)

布局、交互、状态文案完全对齐驱虫 Tab，只做以下替换：

- 三行状态行：`洗澡` / `剪指甲` / `梳毛`（对应 `bath` / `nail_trim` / `grooming`）
- 正常文案 "距离下次日常 XX 天"；过期文案 "距离日常日期已过 XX 天"（红字）
- 未勾选提醒展示 "已关闭提醒"；已勾选但缺少周期展示 "请先设置日常周期"；已勾选但无记录展示 "请先记录日常日期"
- "设置周期" 按钮跳 `/health/routine/cycle?petId=`
- 底部历史列表展示 `洗澡` / `剪指甲` / `梳毛` 标签，左滑编辑/删除

### 4.10 日常记录页面 (`screens/health/routine_record_screen.dart`)

与驱虫记录页一一对应：

- `ChoiceChip` 三选一：洗澡 / 剪指甲 / 梳毛
- 日常日期：默认今天，可改为历史日期，最大值为今天
- 确认按钮调用 `createRoutine` / `updateRoutine` 并刷新 `routineListProvider` + `routineStatusProvider`

### 4.11 日常周期设置页面 (`screens/health/routine_cycle_screen.dart`)

- 三段卡片：洗澡 / 剪指甲 / 梳毛
- 每段一个 `Switch`（提醒开关）+ 一个周期输入框（`FilteringTextInputFormatter.digitsOnly`）
- 默认值：洗澡 14、剪指甲 30、梳毛 7；提交前客户端校验 1-365
- 只提交用户实际填写/调整过的字段；后端 `exclude_unset=True` 仅更新传入字段
- 保存后 `invalidate(routineStatusProvider(petId))` 并刷新 `petListProvider`

---

## 5. 疫苗类型预设值

预设按"国内常见度从高到低"排序，定义在 `backend/app/services/health.py` 的 `VACCINE_PRESETS` 常量中。`GET /api/v1/vaccine-types` 严格按此顺序返回，前端 `vaccination_record_screen.dart` 直接渲染为快选 `ActionChip`。修改预设时请同步本节及 §2.3。

### 猫（6 项）
1. 猫三联疫苗（猫瘟、猫疱疹病毒、猫杯状病毒）
2. 狂犬病疫苗
3. 猫四联疫苗
4. 猫白血病疫苗
5. 猫五联疫苗
6. 猫传染性腹膜炎疫苗

### 狗（8 项）
1. 狂犬病疫苗
2. 犬八联疫苗
3. 犬六联疫苗
4. 犬四联疫苗
5. 犬二联疫苗
6. 犬窝咳疫苗
7. 莱姆病疫苗
8. 犬流感疫苗

> 后端不做白名单校验，只校验长度 1-100；预设之外用户仍可自由输入任何疫苗名称。

---

## 6. 需要创建/修改的文件清单

### 后端
- `backend/app/models/pet.py` - 增加三类驱虫周期 (`combined_deworming_cycle_days`) 和三个驱虫提醒开关字段；日常模块再增加 `bath_cycle_days / nail_trim_cycle_days / grooming_cycle_days` 和三个日常提醒开关字段
- `backend/app/models/weight.py` - 体重 ORM (新建)
- `backend/app/models/deworming.py` - 驱虫 ORM + `DewormingType` 枚举 (新建)
- `backend/app/models/vaccination.py` - 疫苗 ORM (新建)
- `backend/app/models/routine.py` - 日常 ORM + `RoutineType` 枚举 (新建)
- `backend/alembic/versions/a1b2c3d4e5f6_step5_health_fields.py` - 扩展 `dewormingtype` 枚举、补全 pets 上的新字段 (新建)
- `backend/alembic/versions/b2c3d4e5f6a7_step5_routine.py` - 新建 `routines` 表 + `routinetype` 枚举，补全 pets 上的日常字段 (新建)
- `backend/app/schemas/health.py` - 健康管理 Schema，包含体重/驱虫/疫苗/日常四块 (新建)
- `backend/app/schemas/pet.py` - 暴露新增驱虫/日常配置字段
- `backend/app/services/health.py` - 健康业务逻辑 + `VACCINE_PRESETS` 常量 (新建)
- `backend/app/api/v1/health.py` - 健康管理路由 (新建)
- `backend/app/api/v1/router.py` - 注册 health 路由 (修改)

> 复用：`app.services.pet.get_pet_membership` 用于宠物维度的鉴权；`app.dependencies.get_current_user` 用于解析 JWT。

### 前端
- `frontend/lib/models/health.dart` - 健康数据模型 (新建)
- `frontend/lib/models/pet.dart` - Pet 模型同步新增驱虫/日常配置字段
- `frontend/lib/services/health_service.dart` - 健康 API 服务 (新建)
- `frontend/lib/providers/health_provider.dart` - 健康相关 Riverpod providers (新建)
- `frontend/lib/screens/health/health_screen.dart` - 健康主页面，Tab 顺序：体重 → 日常 → 驱虫 → 疫苗
- `frontend/lib/screens/health/weight_tab.dart` - 体重 Tab (新建)
- `frontend/lib/screens/health/deworming_tab.dart` - 驱虫 Tab (新建)
- `frontend/lib/screens/health/vaccination_tab.dart` - 疫苗 Tab (新建)
- `frontend/lib/screens/health/routine_tab.dart` - 日常 Tab (新建)
- `frontend/lib/screens/health/weight_record_screen.dart` - 体重记录/编辑页 (新建)
- `frontend/lib/screens/health/deworming_record_screen.dart` - 驱虫记录/编辑页 (新建)
- `frontend/lib/screens/health/vaccination_record_screen.dart` - 疫苗记录/编辑页 (新建)
- `frontend/lib/screens/health/routine_record_screen.dart` - 日常记录/编辑页 (新建)
- `frontend/lib/screens/health/deworming_cycle_screen.dart` - 驱虫周期设置页 (新建)
- `frontend/lib/screens/health/routine_cycle_screen.dart` - 日常周期设置页 (新建)
- `frontend/lib/config/router.dart` - 注册 `/health/weight/(new|edit)`、`/health/deworming/(new|edit|cycle)`、`/health/vaccination/(new|edit)`、`/health/routine/(new|edit|cycle)` 路由 (修改)

> 路由约定（GoRouter，全部走根 Navigator，参数走 query string）：
> - `/health/weight/new?petId=`
> - `/health/weight/edit?petId=&weightId=&weight=&date=`
> - `/health/deworming/new?petId=`
> - `/health/deworming/edit?petId=&dewormingId=&type=&date=`
> - `/health/deworming/cycle?petId=`
> - `/health/vaccination/new?petId=`
> - `/health/vaccination/edit?petId=&vaccinationId=&type=&date=` （`type` 需 `Uri.encodeQueryComponent` 处理中文）
> - `/health/routine/new?petId=`
> - `/health/routine/edit?petId=&routineId=&type=&date=`
> - `/health/routine/cycle?petId=`

---

## 7. 验收标准

### 体重
- [ ] 后端体重 CRUD API 正常工作
- [ ] Flutter 体重列表按时间倒序展示
- [ ] Flutter 记录体重: 输入体重值+日期，日期默认今天
- [ ] Flutter 体重记录支持编辑和删除 (左滑)

### 驱虫
- [ ] 后端驱虫 CRUD API 正常工作
- [ ] 后端驱虫周期设置 API 正常工作
- [ ] 后端三类驱虫状态 API 正确计算倒计时
- [ ] 三类驱虫的提醒开关能正确控制状态计算
- [ ] Flutter 驱虫倒计时卡片正确显示
- [ ] Flutter 倒计时过期时红字显示 "距离驱虫日期已过 XX 天"
- [ ] Flutter 未勾选提醒时展示“已关闭提醒”
- [ ] Flutter 未设置周期时提示设置
- [ ] Flutter 记录驱虫: 选择内驱/外驱/内外同驱+日期
- [ ] Flutter 驱虫周期设置页面正常工作

### 疫苗
- [ ] 后端疫苗 CRUD API 正常工作
- [ ] 后端疫苗类型预设 API 按宠物类型返回
- [ ] Flutter 疫苗列表按时间倒序展示
- [ ] Flutter 记录疫苗: 预设标签快选 + 自定义输入 + 日期
- [ ] Flutter 预设标签根据宠物类型动态变化

### 日常
- [ ] 后端日常 CRUD API 正常工作
- [ ] 后端日常周期设置 API 正常工作
- [ ] 后端三类日常状态 API 正确计算倒计时
- [ ] 三类日常的提醒开关能正确控制状态计算
- [ ] Flutter 日常倒计时卡片正确显示
- [ ] Flutter 倒计时过期时红字显示 "距离日常日期已过 XX 天"
- [ ] Flutter 未勾选提醒时展示 "已关闭提醒"
- [ ] Flutter 未设置周期时提示设置
- [ ] Flutter 记录日常: 选择洗澡/剪指甲/梳毛 + 日期
- [ ] Flutter 日常周期设置页面正常工作

### 通用
- [ ] Flutter 健康页面四个 Tab (体重/日常/驱虫/疫苗) 切换流畅，顺序固定
- [ ] Flutter 宠物选择器切换后数据正确刷新
- [ ] 所有记录的日期默认为当天，支持手动修改
- [ ] 三类驱虫、三类日常的状态、周期和提醒开关彼此独立
- [ ] 空列表时展示友好的提示信息
