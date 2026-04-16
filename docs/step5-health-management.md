# Step 5: 健康管理 (体重/驱虫/疫苗)

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL 技术栈。本步骤实现健康管理模块，包括体重记录、驱虫管理和疫苗管理三个子功能。

**前置依赖**: Step 3 已完成 (宠物档案管理)，宠物选择器组件可用。

---

## 本步骤目标

1. 后端实现体重 CRUD API + 历史列表查询
2. 后端实现驱虫 CRUD API + 三类驱虫周期管理 + 倒计时计算
3. 后端实现疫苗 CRUD API + 疫苗类型预设
4. Flutter 实现「健康」页面，包含三个子 Tab、动态 FAB 和完整交互

---

## 1. 页面结构概览

```
┌─────────────────────────────────┐
│  橘子 ▼               体重 | 驱虫 | 疫苗 │
├─────────────────────────────────┤
│                                 │
│         (子页面内容区域)          │
│     根据右上角 Tab 切换展示       │
│                                 │
│                                 │
│                          ┌────┐ │
│                          │ ＋ │ │  ← 浮动记录按钮
│                          └────┘ │
├─────────────────────────────────┤
│  记录  │  健康  │ 时间轴 │  AI  │ 我的 │
└─────────────────────────────────┘
```

- 顶部左侧: 宠物选择器 (单选模式)
- 顶部右侧: 体重/驱虫/疫苗三个 Tab 按钮
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
- 若某类驱虫未勾选提醒，则该类返回 `reminder_enabled=false`，并且 `next_due_at`、`days_remaining`、`is_overdue` 返回 `null`
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
  "vaccine_type": "猫三联",
  "vaccinated_at": "2024-01-15"
}
```

成功响应 (201):
```json
{
  "id": 1,
  "pet_id": 1,
  "user_id": 1,
  "vaccine_type": "猫三联",
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
      "vaccine_type": "猫三联",
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
  "vaccine_type": "狂犬疫苗",
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
  "preset_types": ["猫三联", "狂犬疫苗", "猫五联"],
  "pet_type": "cat"
}
```

此 API 不需要数据库，直接返回硬编码的预设值:
- 猫: 猫三联、猫五联、狂犬疫苗
- 狗: 犬二联、犬四联、犬六联、犬八联、狂犬疫苗

---

## 3. 后端实现要点

### 3.1 Pydantic Schema (`app/schemas/health.py`)

```python
from pydantic import BaseModel, field_validator
from datetime import date, datetime
from decimal import Decimal
from app.models.deworming import DewormingType

class WeightCreate(BaseModel):
    weight_kg: Decimal
    recorded_at: date

    @field_validator("weight_kg")
    @classmethod
    def validate_weight(cls, v):
        if v <= 0 or v > 200:
            raise ValueError("体重必须在 0-200kg 之间")
        return v

    @field_validator("recorded_at")
    @classmethod
    def validate_date(cls, v):
        if v > date.today():
            raise ValueError("记录日期不能是未来日期")
        return v

class WeightResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    weight_kg: Decimal
    recorded_at: date
    created_at: datetime

    model_config = {"from_attributes": True}

class DewormingCreate(BaseModel):
    deworming_type: DewormingType
    dewormed_at: date

    @field_validator("dewormed_at")
    @classmethod
    def validate_date(cls, v):
        if v > date.today():
            raise ValueError("驱虫日期不能是未来日期")
        return v

class DewormingResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    deworming_type: DewormingType
    dewormed_at: date
    created_at: datetime

    model_config = {"from_attributes": True}

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
    def validate_cycle(cls, v):
        if v is not None and (v < 1 or v > 365):
            raise ValueError("驱虫周期必须在 1-365 天之间")
        return v

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

class VaccinationCreate(BaseModel):
    vaccine_type: str
    vaccinated_at: date

    @field_validator("vaccine_type")
    @classmethod
    def validate_type(cls, v):
        v = v.strip()
        if not v or len(v) > 100:
            raise ValueError("疫苗类型长度为1-100个字符")
        return v

class VaccinationResponse(BaseModel):
    id: int
    pet_id: int
    user_id: int
    vaccine_type: str
    vaccinated_at: date
    created_at: datetime

    model_config = {"from_attributes": True}
```

### 3.2 驱虫状态计算逻辑

```python
from datetime import date, timedelta

async def get_deworming_status(pet_id: int, db: AsyncSession) -> DewormingStatusResponse:
    pet = await db.get(Pet, pet_id)

    internal_status = await _calc_status(
        pet_id=pet_id,
        deworming_type=DewormingType.INTERNAL,
        cycle_days=pet.internal_deworming_cycle_days,
        reminder_enabled=pet.internal_reminder_enabled,
        db=db,
    )
    external_status = await _calc_status(
        pet_id=pet_id,
        deworming_type=DewormingType.EXTERNAL,
        cycle_days=pet.external_deworming_cycle_days,
        reminder_enabled=pet.external_reminder_enabled,
        db=db,
    )
    combined_status = await _calc_status(
        pet_id=pet_id,
        deworming_type=DewormingType.COMBINED,
        cycle_days=pet.combined_deworming_cycle_days,
        reminder_enabled=pet.combined_reminder_enabled,
        db=db,
    )

    return DewormingStatusResponse(
        internal=internal_status,
        external=external_status,
        combined=combined_status,
    )

async def _calc_status(
    pet_id: int,
    deworming_type: DewormingType,
    cycle_days: int | None,
    reminder_enabled: bool,
    db: AsyncSession,
) -> DewormingStatusItem:
    result = await db.execute(
        select(Deworming)
        .where(Deworming.pet_id == pet_id, Deworming.deworming_type == deworming_type)
        .order_by(Deworming.dewormed_at.desc())
        .limit(1)
    )
    last_record = result.scalar_one_or_none()

    if not reminder_enabled:
        return DewormingStatusItem(
            reminder_enabled=False,
            last_dewormed_at=last_record.dewormed_at if last_record else None,
            cycle_days=cycle_days,
            next_due_at=None,
            days_remaining=None,
            is_overdue=None,
        )

    if not last_record or not cycle_days:
        return DewormingStatusItem(
            reminder_enabled=True,
            last_dewormed_at=last_record.dewormed_at if last_record else None,
            cycle_days=cycle_days,
            next_due_at=None,
            days_remaining=None,
            is_overdue=None,
        )

    next_due = last_record.dewormed_at + timedelta(days=cycle_days)
    remaining = (next_due - date.today()).days

    return DewormingStatusItem(
        reminder_enabled=True,
        last_dewormed_at=last_record.dewormed_at,
        cycle_days=cycle_days,
        next_due_at=next_due,
        days_remaining=remaining,
        is_overdue=remaining < 0,
    )
```

---

## 4. Flutter 页面设计

### 4.1 健康页面主框架 (`screens/health/health_screen.dart`)

顶部使用宠物选择器 (单选) + 右侧 Tab 切换 (体重/驱虫/疫苗)。
使用 `TabBarView` 实现三个子页面的切换。
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
│  ┌──────────┐ ┌──────────┐     │
│  │   内驱    │ │   外驱    │     │
│  └──────────┘ └──────────┘     │
│  ┌──────────────┐              │
│  │   内外同驱     │              │
│  └──────────────┘              │
│  (SegmentedButton 三选一)        │
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
│  ☑ 内驱提醒                      │
│  周期: [ 30 ] 天                 │
│                                 │
│  ☑ 外驱提醒                      │
│  周期: [ 30 ] 天                 │
│                                 │
│  ☐ 内外同驱提醒                  │
│  周期: [ 90 ] 天                 │
│                                 │
│  ┌─────────────────────────┐    │
│  │         保存设置          │    │
│  └─────────────────────────┘    │
└─────────────────────────────────┘
```

- 用于统一编辑三类驱虫的周期值
- 也可同步查看或修改三类提醒开关
- 在驱虫主页面勾选/取消勾选后，应同步刷新这里的状态

### 4.7 疫苗 Tab (`screens/health/vaccination_tab.dart`)

```
┌─────────────────────────────────┐
│                                 │
│  ── 疫苗记录 ──────────────────  │
│                                 │
│  📅 2024-01-15                  │
│     猫三联                      │
│  ─────────────────              │
│  📅 2023-07-20                  │
│     狂犬疫苗                    │
│  ─────────────────              │
│  📅 2023-01-10                  │
│     猫三联                      │
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
│  ┌────┐ ┌────┐ ┌────┐         │
│  │猫三联│ │狂犬 │ │猫五联│ ← 预设快选 │
│  └────┘ └────┘ └────┘         │
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

---

## 5. 疫苗类型预设值

### 猫
- 猫三联 (猫瘟、猫疱疹病毒、猫杯状病毒)
- 猫五联
- 狂犬疫苗

### 狗
- 犬二联
- 犬四联
- 犬六联
- 犬八联
- 狂犬疫苗

---

## 6. 需要创建/修改的文件清单

### 后端
- `backend/app/models/pet.py` - 增加三类驱虫周期和提醒开关字段
- `backend/alembic/versions/*.py` - 为新增驱虫配置字段补充迁移
- `backend/app/schemas/health.py` - 健康管理 Schema (新建)
- `backend/app/schemas/pet.py` - 暴露新增驱虫配置字段
- `backend/app/api/v1/health.py` - 健康管理路由 (新建)
- `backend/app/api/v1/router.py` - 注册 health 路由 (修改)

### 前端
- `frontend/lib/models/health.dart` - 健康数据模型 (新建)
- `frontend/lib/services/health_service.dart` - 健康 API 服务 (新建)
- `frontend/lib/providers/health_provider.dart` - 健康状态管理 (新建)
- `frontend/lib/screens/health/health_screen.dart` - 健康主页面 (实现)
- `frontend/lib/screens/health/weight_tab.dart` - 体重 Tab (新建)
- `frontend/lib/screens/health/deworming_tab.dart` - 驱虫 Tab (新建)
- `frontend/lib/screens/health/vaccination_tab.dart` - 疫苗 Tab (新建)
- `frontend/lib/screens/health/weight_record_screen.dart` - 体重记录页 (新建)
- `frontend/lib/screens/health/deworming_record_screen.dart` - 驱虫记录页 (新建)
- `frontend/lib/screens/health/vaccination_record_screen.dart` - 疫苗记录页 (新建)
- `frontend/lib/screens/health/deworming_cycle_screen.dart` - 驱虫周期设置页 (新建)

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

### 通用
- [ ] Flutter 健康页面三个 Tab 切换流畅
- [ ] Flutter 宠物选择器切换后数据正确刷新
- [ ] 所有记录的日期默认为当天，支持手动修改
- [ ] 三类驱虫的状态、周期和提醒开关彼此独立
- [ ] 空列表时展示友好的提示信息
