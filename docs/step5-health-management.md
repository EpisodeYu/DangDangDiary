# Step 5: 健康管理 (体重/驱虫/疫苗)

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL 技术栈。本步骤实现健康管理模块，包括体重记录、驱虫管理和疫苗管理三个子功能。

**前置依赖**: Step 3 已完成 (宠物档案管理)，宠物选择器组件可用。

---

## 本步骤目标

1. 后端实现体重 CRUD API + 时间轴查询
2. 后端实现驱虫 CRUD API + 驱虫周期管理 + 倒计时计算
3. 后端实现疫苗 CRUD API + 疫苗类型预设
4. Flutter 实现「健康」页面，包含三个子 Tab 及其完整交互

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
  "weight_kg": 4.5,
  "recorded_at": "2024-01-15",
  "created_at": "2024-01-20T10:30:00"
}
```

验证规则:
- weight_kg: 大于 0，最多两位小数，最大 200kg
- recorded_at: 有效日期，不能是未来日期

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
      "weight_kg": 4.5,
      "recorded_at": "2024-01-15",
      "created_at": "2024-01-20T10:30:00"
    },
    ...
  ],
  "total": 30,
  "page": 1,
  "page_size": 50
}
```

排序: 按 recorded_at 降序 (最新的在前)

#### 删除体重记录

```
DELETE /api/v1/weights/{weight_id}
```

成功响应 (204)

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
  "deworming_type": "internal",
  "dewormed_at": "2024-01-15"
}
```

成功响应 (201):
```json
{
  "id": 1,
  "pet_id": 1,
  "deworming_type": "internal",
  "dewormed_at": "2024-01-15",
  "created_at": "2024-01-20T10:30:00"
}
```

验证规则:
- deworming_type: 必须是 "internal" (内驱) 或 "external" (外驱)
- dewormed_at: 有效日期，不能是未来日期

#### 获取驱虫历史

```
GET /api/v1/pets/{pet_id}/dewormings?page=1&page_size=50
```

返回格式同体重，按 dewormed_at 降序

#### 删除驱虫记录

```
DELETE /api/v1/dewormings/{deworming_id}
```

#### 设置驱虫周期

```
PUT /api/v1/pets/{pet_id}/deworming-cycle
Content-Type: application/json
```

请求体:
```json
{
  "internal_cycle_days": 30,
  "external_cycle_days": 30
}
```

成功响应 (200):
```json
{
  "internal_cycle_days": 30,
  "external_cycle_days": 30
}
```

验证规则:
- 两个字段都可选，只更新传入的字段
- 范围: 1-365 天

#### 获取驱虫状态 (倒计时)

```
GET /api/v1/pets/{pet_id}/deworming-status
```

成功响应 (200):
```json
{
  "internal": {
    "last_dewormed_at": "2024-01-01",
    "cycle_days": 30,
    "next_due_at": "2024-01-31",
    "days_remaining": 11,
    "is_overdue": false
  },
  "external": {
    "last_dewormed_at": "2023-12-15",
    "cycle_days": 30,
    "next_due_at": "2024-01-14",
    "days_remaining": -6,
    "is_overdue": true
  }
}
```

计算逻辑:
- `next_due_at` = 最后一次驱虫日期 + 周期天数
- `days_remaining` = next_due_at - 今天 (正数=剩余天数, 负数=过期天数)
- `is_overdue` = days_remaining < 0
- 如果未设置驱虫周期或没有驱虫记录，对应字段返回 null

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
  "vaccine_type": "猫三联",
  "vaccinated_at": "2024-01-15",
  "created_at": "2024-01-20T10:30:00"
}
```

验证规则:
- vaccine_type: 不为空，长度 <= 100
- vaccinated_at: 有效日期，不能是未来日期

#### 获取疫苗历史

```
GET /api/v1/pets/{pet_id}/vaccinations?page=1&page_size=50
```

排序: 按 vaccinated_at 降序

#### 删除疫苗记录

```
DELETE /api/v1/vaccinations/{vaccination_id}
```

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
    weight_kg: Decimal
    recorded_at: date
    created_at: datetime

    class Config:
        from_attributes = True

class DewormingCreate(BaseModel):
    deworming_type: DewormingType
    dewormed_at: date

class DewormingResponse(BaseModel):
    id: int
    pet_id: int
    deworming_type: DewormingType
    dewormed_at: date
    created_at: datetime

    class Config:
        from_attributes = True

class DewormingCycleUpdate(BaseModel):
    internal_cycle_days: int | None = None
    external_cycle_days: int | None = None

    @field_validator("internal_cycle_days", "external_cycle_days")
    @classmethod
    def validate_cycle(cls, v):
        if v is not None and (v < 1 or v > 365):
            raise ValueError("驱虫周期必须在 1-365 天之间")
        return v

class DewormingStatusItem(BaseModel):
    last_dewormed_at: date | None
    cycle_days: int | None
    next_due_at: date | None
    days_remaining: int | None
    is_overdue: bool | None

class DewormingStatusResponse(BaseModel):
    internal: DewormingStatusItem
    external: DewormingStatusItem

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
    vaccine_type: str
    vaccinated_at: date
    created_at: datetime

    class Config:
        from_attributes = True
```

### 3.2 驱虫状态计算逻辑

```python
from datetime import date

async def get_deworming_status(pet_id: int, db: AsyncSession) -> DewormingStatusResponse:
    pet = await db.get(Pet, pet_id)

    internal_status = await _calc_status(
        pet_id, DewormingType.INTERNAL, pet.internal_deworming_cycle_days, db
    )
    external_status = await _calc_status(
        pet_id, DewormingType.EXTERNAL, pet.external_deworming_cycle_days, db
    )

    return DewormingStatusResponse(internal=internal_status, external=external_status)

async def _calc_status(
    pet_id: int, deworming_type: DewormingType, cycle_days: int | None, db: AsyncSession
) -> DewormingStatusItem:
    # 获取最后一次驱虫记录
    result = await db.execute(
        select(Deworming)
        .where(Deworming.pet_id == pet_id, Deworming.deworming_type == deworming_type)
        .order_by(Deworming.dewormed_at.desc())
        .limit(1)
    )
    last_record = result.scalar_one_or_none()

    if not last_record or not cycle_days:
        return DewormingStatusItem(
            last_dewormed_at=last_record.dewormed_at if last_record else None,
            cycle_days=cycle_days,
            next_due_at=None,
            days_remaining=None,
            is_overdue=None,
        )

    from datetime import timedelta
    next_due = last_record.dewormed_at + timedelta(days=cycle_days)
    remaining = (next_due - date.today()).days

    return DewormingStatusItem(
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

### 4.3 体重记录页面 (底部弹出 Sheet 或新页面)

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
│  ┌──────────────────────────┐   │
│  │ 距离下次内驱: 15 天        │   │
│  │ 距离下次外驱: 已过期 3 天  │   │  ← 过期红字显示
│  └──────────────────────────┘   │
│  (点击可设置驱虫周期)             │
│                                 │
│  ── 驱虫记录 ──────────────────  │
│                                 │
│  📅 2024-01-15                  │
│     内驱                        │
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
  - 正常: 黑色文字 "距离下次内驱: XX 天"
  - 过期: **红色文字** "距离驱虫日期已过 XX 天"
  - 未设置周期: 提示 "请先设置驱虫周期"
- 点击卡片弹出驱虫周期设置对话框
- 下方展示驱虫历史记录，标注内驱/外驱
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
│  (SegmentedButton 二选一)        │
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

### 4.6 驱虫周期设置对话框

```
┌─────────────────────────┐
│  设置驱虫周期             │
│                         │
│  内驱周期                │
│  ┌──────────────┐ 天    │
│  │     30       │       │
│  └──────────────┘       │
│                         │
│  外驱周期                │
│  ┌──────────────┐ 天    │
│  │     30       │       │
│  └──────────────┘       │
│                         │
│  [取消]        [确认]    │
└─────────────────────────┘
```

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
- `backend/app/schemas/health.py` - 健康管理 Schema (新建)
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
- `frontend/lib/screens/health/weight_record_sheet.dart` - 体重记录页 (新建)
- `frontend/lib/screens/health/deworming_record_sheet.dart` - 驱虫记录页 (新建)
- `frontend/lib/screens/health/vaccination_record_sheet.dart` - 疫苗记录页 (新建)
- `frontend/lib/screens/health/deworming_cycle_dialog.dart` - 驱虫周期设置 (新建)

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
- [ ] 后端驱虫状态 API 正确计算倒计时
- [ ] Flutter 驱虫倒计时卡片正确显示
- [ ] Flutter 倒计时过期时红字显示 "距离驱虫日期已过 XX 天"
- [ ] Flutter 未设置周期时提示设置
- [ ] Flutter 记录驱虫: 选择内驱/外驱+日期
- [ ] Flutter 驱虫周期设置对话框正常工作

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
- [ ] 空列表时展示友好的提示信息
