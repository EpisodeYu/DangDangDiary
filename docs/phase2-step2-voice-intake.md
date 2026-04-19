# Phase 2 - Step 2: 语音快速记录

## 项目背景

Phase 1 的记录入口完全是"打开页面 → 选宠物 → 填表单 → 提交"的手动流程。在驱虫、疫苗这类"事件发生时人手上有猫/狗、不方便点屏幕"的场景，手动流程很容易被用户遗忘或推迟。本步骤引入一个"长按语音 → 自动起草记录"的快速入口：用户在记录页长按语音按钮说一句话（例如"今天给咪咪做了驱虫"），APP 自动识别意图、抽取关键信息、预填到对应的创建页，只有在用户确认后才真正落库。

本步骤定位为"抽取器 + 建议者"而非"执行者"——写入型日记应用对脏数据零容忍，宁可多一跳交互也不允许 LLM 误识别直接落库。

**前置依赖**：Phase 1 全部 8 步已完成；本功能复用 Step 3（宠物档案）、Step 4（照片记录）、Step 5（健康管理）的写接口作为最终落库通道。

---

## 本步骤目标

1. 前端：记录页增加"长按录音"按钮，松手即上传；录音过程中提供取消与波形反馈。
2. 后端：新增 `POST /api/v1/voice/intake`——接受音频文件，内部串行「STT → LLM 意图抽取」，返回结构化草稿 + 缺失字段清单，**不直接落库**。
3. 后端：新增 `POST /api/v1/voice/intake/confirm`——接受修订后的草稿，转发到现有 `create_deworming` / `create_vaccination` / `create_weight` / `create_routine` 内部服务完成写入；带幂等键防重复提交。
4. 前端：根据后端返回分流：字段齐全 + 高置信 → 直接提交并展示 5 秒"撤销"提示；缺字段 → 跳到对应创建页并高亮缺项；意图未知 → 展示转写文本，兜底为"文字备忘"或放弃。
5. 后端：新增 `voice_intake_logs` 表，落 transcript、LLM 原始响应、最终动作，便于复盘与 prompt 调参。

---

## 0. 与 Phase 1 既有约定的关系

- **全局规则 §4 API 约定**（见 [docs/00-global-rules.md](00-global-rules.md)）：snake_case、错误结构 `{code, message, details}`、创建返回完整对象、删除 204。本步所有新接口严格对齐。
- **全局规则 §媒体处理**：原文要求"照片先在前端做格式转换"。音频同理——Flutter 端直接录 AAC/M4A（由 `record` 包默认输出），后端只接受 `audio/m4a`、`audio/aac`、`audio/mpeg` 三种 MIME，其它拒收。
- **复用而非重写写入逻辑**：本步不新增业务表（`voice_intake_logs` 仅为审计日志），不绕过现有的权限校验。`confirm` 接口内部必须走 `services/health.py` 等同一层服务，权限（EDITOR 及以上）随 Phase 2 Step 1 的成员角色自动生效。
- **第三方服务**：沿用 Phase 2 既有规划，STT 用阿里云**录音文件识别极速版**（或 Paraformer），LLM 用**通义千问** JSON mode，不引入新厂商账号。

---

## 1. 整体链路

```
长按录音 (Flutter)
    │  松手
    ▼
上传音频 multipart  ──►  POST /api/v1/voice/intake
                            │
                            ├─ STT (阿里云)           → transcript
                            ├─ LLM (通义千问 JSON mode) → {intent, fields, confidence}
                            ├─ 字段归一化 (日期 / 宠物名 → pet_id / 枚举)
                            └─ 返回 draft + missing_fields + needs_confirm
    │
    ▼
前端分流：
    ├─ STT 失败              → Toast 提示重录
    ├─ intent=unknown         → 展示 transcript，提供"作为文字备忘"或放弃
    ├─ 字段缺失               → 跳对应创建页 + 预填 + 高亮缺项
    ├─ 齐全 + 高置信 + 用户设置允许 → 直接 confirm + 5 秒撤销
    └─ 齐全 + 低置信          → 确认卡片 → 用户点确认后 confirm
    │
    ▼
POST /api/v1/voice/intake/confirm  ──►  内部调用 create_deworming / ...
```

---

## 2. 数据模型变更

### 2.1 新增 `VoiceIntakeLog` 模型

新建 [backend/app/models/voice_intake.py](../backend/app/models/voice_intake.py)：

```python
import enum
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, Enum, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from app.database import Base
from app.utils.time import utcnow


class VoiceIntakeStatus(str, enum.Enum):
    STT_FAILED = "stt_failed"
    INTENT_UNKNOWN = "intent_unknown"
    DRAFT_PENDING = "draft_pending"
    CONFIRMED = "confirmed"
    CANCELED = "canceled"


class VoiceIntakeLog(Base):
    __tablename__ = "voice_intake_logs"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False, index=True)
    request_id: Mapped[str] = mapped_column(String(40), unique=True, nullable=False)
    audio_object_key: Mapped[str | None] = mapped_column(String(255), nullable=True)
    transcript: Mapped[str | None] = mapped_column(Text, nullable=True)
    llm_raw: Mapped[str | None] = mapped_column(Text, nullable=True)
    intent: Mapped[str | None] = mapped_column(String(32), nullable=True)
    confidence: Mapped[int | None] = mapped_column(Integer, nullable=True)  # 0-100
    status: Mapped[VoiceIntakeStatus] = mapped_column(Enum(VoiceIntakeStatus), nullable=False)
    committed_entity_type: Mapped[str | None] = mapped_column(String(32), nullable=True)
    committed_entity_id: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime, default=utcnow, index=True)
    confirmed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
```

> 音频原文件只保留到 `confirm` 或 `canceled` 为止（默认 24h），到期由后台任务从 MinIO 清理。日志本身长期保留，用于 prompt/召回率回归。

### 2.2 Alembic 迁移

新建一个版本文件 `xxxxxx_add_voice_intake_logs.py`：
- 新建 `voice_intake_logs` 表 + `voiceintakestatus` 枚举；
- `user_id` 外键 `users.id`；`created_at` 建索引。

---

## 3. 后端接口

### 3.1 `POST /api/v1/voice/intake`

**请求**（`multipart/form-data`）：
| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `audio_file` | file | 是 | m4a/aac/mp3，单段 ≤ 30s，≤ 2MB |
| `default_pet_id` | int | 否 | 当前记录页选中的宠物，用于消歧 |
| `client_request_id` | str | 是 | UUID，前端生成；Redis 去重（TTL 10 分钟） |

**响应 200**：
```json
{
  "request_id": "8b1c...",
  "status": "draft_pending",
  "transcript": "今天给咪咪做了驱虫",
  "intent": "deworming",
  "confidence": 82,
  "needs_confirm": false,
  "draft": {
    "pet_id": 3,
    "deworming_type": null,
    "dewormed_at": "2026-04-19"
  },
  "missing_fields": ["deworming_type"]
}
```

**响应语义**：
| 场景 | HTTP | `status` | `code` |
|---|---|---|---|
| STT 无结果（静音、噪音、<0.5s） | 200 | `stt_failed` | — |
| 听清但非记录类（闲聊、提问） | 200 | `intent_unknown` | — |
| 意图明确、字段缺失或置信度偏低 | 200 | `draft_pending` | — |
| 音频格式 / 时长 / 大小非法 | 400 | — | `voice_audio_invalid` |
| 第三方服务暂不可用（STT 或 LLM 5xx） | 503 | — | `voice_upstream_unavailable` |

> 业务语义的"失败"（听不清、听不懂）一律走 200 + `status`，因为这是产品正常路径；只有调用方明显错误或上游真挂了才用 4xx/5xx——跟 Step 4 场景识别失败（400 `photo_not_pet`）一致的思路。

### 3.2 `POST /api/v1/voice/intake/confirm`

**请求**（JSON）：
```json
{
  "request_id": "8b1c...",
  "intent": "deworming",
  "payload": {
    "pet_id": 3,
    "deworming_type": "combined",
    "dewormed_at": "2026-04-19"
  }
}
```

- `request_id` 必须是同用户在 `intake` 阶段返回的 id，且该 log 状态为 `draft_pending`；否则 `409 voice_intake_invalid_state`。
- 内部按 `intent` 分派到现有服务，复用其 Pydantic schema 做参数校验——LLM 抽错字段会在这一步被挡住：
  | intent | 调用 |
  |---|---|
  | `deworming` | `services.health.create_deworming` |
  | `vaccination` | `services.health.create_vaccination` |
  | `weight` | `services.health.create_weight` |
  | `routine` | `services.health.create_routine` |
- 成功：返回被调用服务的标准响应对象；同步把 log 置为 `confirmed`，记录 `committed_entity_type/id`。
- 权限：复用各服务现有的 EDITOR 及以上校验，本接口自身**不重复判断**。

### 3.3 `DELETE /api/v1/voice/intake/{request_id}`

用于"5 秒内撤销"场景的软取消——只有 `draft_pending` 状态可撤销；`confirmed` 后必须走对应资源的 `DELETE` 接口（已有）。响应 204。

### 3.4 路由注册

文件：[backend/app/api/v1/router.py](../backend/app/api/v1/router.py) 加入 `voice.router`；新建 [backend/app/api/v1/voice.py](../backend/app/api/v1/voice.py)。

---

## 4. 服务层设计

### 4.1 `services/voice_intake.py`（新建）

核心函数：

```python
async def intake(audio: UploadFile, user: User, default_pet_id: int | None,
                 client_request_id: str) -> IntakeResult: ...

async def confirm(request_id: str, user: User, intent: str,
                  payload: dict) -> Any: ...
```

内部步骤：

1. **预校验**：MIME / 时长 / 大小；`client_request_id` 走 Redis `SETNX` 去重。
2. **音频落 MinIO**：放到 `voice-intake/<user_id>/<yyyymmdd>/<uuid>.m4a`，bucket 与照片分开，生命周期策略 24h。
3. **STT**：`services/stt.py`（新建，封装阿里云 SDK）；异常 → `stt_failed`，不重试。
4. **LLM**：`services/llm.py`（新建，封装通义千问，强 JSON mode），prompt 见 §5；超时 8s，失败 1 次重试。
5. **归一化**（`_normalize_draft`）：
   - 相对日期："今天/昨天/上周三" → 按服务器 UTC + 用户 profile 的时区解析为 `date`；**绝不让 LLM 自己算日期**。
   - 宠物解析：LLM 输出 `pet_name`（字符串），后端在当前用户 `pets` 列表里做精确 → 模糊匹配；多候选或无匹配时置 `pet_id=null`、加入 `missing_fields`；`default_pet_id` 仅在 LLM 未给出 `pet_name` 时兜底。
   - 枚举（`deworming_type`、`vaccine_type` 等）：LLM 必须返回枚举值字面量（`internal` / `external` / `combined`），否则视为缺失。
6. **写 log**：`draft_pending` / `stt_failed` / `intent_unknown` 三种之一。
7. **返回结构体**。

### 4.2 `services/stt.py`、`services/llm.py`（新建）

- 薄封装，只暴露 `transcribe(bytes, mime) -> str` 和 `extract_intent(transcript, context) -> dict`。
- 所有第三方 key 从 `config.py` 读 `.env`（`ALIYUN_STT_*`、`TONGYI_API_KEY`），符合全局规则。
- 单元测试通过注入 fake client 覆盖，不打真实网络。

---

## 5. LLM Prompt 设计

JSON mode + 严格 schema。系统提示词要点：

```
你是一个宠物日记的信息抽取助手。用户会说一句中文，你必须输出 JSON，字段如下：
{
  "intent": "deworming" | "vaccination" | "weight" | "routine" | "photo_note" | "unknown",
  "pet_name": string | null,            // 用户提到的宠物名，没有则 null
  "dewormed_at": "YYYY-MM-DD" | "today" | "yesterday" | "N_days_ago:<n>" | null,
  "deworming_type": "internal" | "external" | "combined" | null,
  "vaccine_name": string | null,
  "vaccinated_at": <同 dewormed_at>,
  "weight_kg": number | null,
  "weighed_at": <同 dewormed_at>,
  "routine_type": "feed" | "walk" | "bath" | "grooming" | "other" | null,
  "routine_at": <同 dewormed_at>,
  "note": string | null,                // 用户附加备注
  "confidence": integer 0-100           // 你对整体抽取的信心
}

规则：
1. 日期一律返回上述受限格式，不要自己算成 "YYYY-MM-DD"，由服务端解析。
2. 只要一个字段你没有明确听到，就返回 null；禁止猜测。
3. 如果这句话不是在记一件宠物相关的事，intent 直接返回 "unknown"，其余字段 null。
4. 只输出 JSON，不要解释。
```

- 温度 0，top_p 1。
- prompt 版本号随 log 一起存，便于 A/B。
- 上线前备一份金标集（20-30 条典型语句 × 预期 JSON），在 CI 里跑 `llm.extract_intent` 的离线回归——允许轻度偏移，但 `intent` 必须 100% 命中。

---

## 6. 前端设计

### 6.1 依赖

`pubspec.yaml` 新增：
- `record: ^5.x`（录音）
- `permission_handler`（已在 Phase 1 其它模块用过，确认是否需要新增 `RECORD_AUDIO`）
- `uuid`（生成 `client_request_id`）

Android `AndroidManifest.xml` 追加 `<uses-permission android:name="android.permission.RECORD_AUDIO"/>`。

### 6.2 `VoiceRecordButton` 新组件

位置：[frontend/lib/widgets/voice_record_button.dart](../frontend/lib/widgets/voice_record_button.dart)（新建）

- 长按开始录音，松手结束并上传；按住状态展示波形 + 计时。
- 上滑取消（仿微信交互）；取消则本地丢弃，不调用接口。
- 超过 30s 强制停止并上传。
- 录音进行中禁用页面其它按钮，避免同时上传其它照片。

### 6.3 记录页集成

文件：[frontend/lib/screens/record/record_screen.dart](../frontend/lib/screens/record/record_screen.dart)

在照片上传区下方加一行 `VoiceRecordButton`。松手后：

1. 调用 `VoiceService.intake(file, defaultPetId, requestId)`。
2. 根据 `status` + `needs_confirm` + `missing_fields` 分流（见 §7）。

### 6.4 服务层

新建 [frontend/lib/services/voice_service.dart](../frontend/lib/services/voice_service.dart)：`intake`、`confirm`、`cancel` 三个方法，统一走项目现有的 `Dio` 实例 + 拦截器（Phase 1 已处理 401 刷新）。

---

## 7. 识别失败与信息不足的分层处理（核心 UX）

| 后端返回 | 前端行为 |
|---|---|
| `status=stt_failed` | 轻量 Toast "没听清，再说一次"；按钮恢复可按，不跳页 |
| `status=intent_unknown` | 弹出 BottomSheet 展示 transcript，两个按钮："作为文字备忘保存"（走 Phase 2 后续的备忘 API，若尚未上线则直接放弃） / "我再说一遍" |
| `draft_pending` + `missing_fields` 非空 | 按 `intent` 跳 `deworming_record_screen` / `vaccination_record_screen` 等，路由参数带 `draft` + `missing_fields`；缺字段的输入框加红色边框和 helper text "语音中未听到，请补充" |
| `draft_pending` + `missing_fields` 空 + `confidence ≥ 70` + 用户设置 `voice_auto_commit=true` | 直接 `confirm`；成功后在记录页顶部 `SnackBar` 提示"已创建驱虫记录 · 撤销"，5 秒内点撤销 → 调 `DELETE` |
| `draft_pending` + `missing_fields` 空 + `confidence < 70` 或用户未开启自动提交 | 弹出预览卡片，展示"识别结果：给咪咪创建驱虫记录 · 今天 · 体内体外同驱"，"确认" / "修改"两个按钮；"修改"跳创建页预填；"确认"调 `confirm` |

**设计原则**：
- 撤销 > 确认弹窗。概率系统最好的错处理就是让用户可回滚，而不是事先反复确认。
- 缺字段一律跳已有创建页，不要在记录页内加一堆弹窗——既复用 UI，又让用户在熟悉的界面补全。
- `voice_auto_commit` 默认关闭；开关放在"我的 → 设置 → 语音记录"里，并写清楚"允许语音直接创建记录，有 5 秒撤销窗口"。

---

## 8. 权限与安全

- 接口要求登录态，复用 `dependencies.get_current_user`。
- `confirm` 的 payload 里 `pet_id` 必须通过 `services/pet.py` 的成员校验（EDITOR 及以上），**不允许**因为是"语音渠道"就放宽。
- `client_request_id` 去重：同一 id 10 分钟内重复提交直接返回首次结果，避免网络抖动导致二次落库。
- 音频落 MinIO 时设置 24h 生命周期策略；日志保留但不含音频 URL（只存 object key，不对外返回）。
- `.env` 新增变量（仅示例键名，值由运维配置）：
  - `ALIYUN_STT_ACCESS_KEY_ID` / `ALIYUN_STT_ACCESS_KEY_SECRET` / `ALIYUN_STT_APP_KEY`
  - `TONGYI_API_KEY` / `TONGYI_MODEL`（默认 `qwen-plus`）
  - `VOICE_INTAKE_MAX_SECONDS`（默认 30）
  - `VOICE_INTAKE_MAX_MB`（默认 2）
- `.env.example` 同步加占位符，不写真实 key（遵循全局规则）。

---

## 9. 测试计划

### 9.1 后端

- 单元：`services/voice_intake.py` 的 `_normalize_draft`——覆盖"今天/昨天/N 天前/具体日期/无日期"、"多宠物歧义"、"枚举缺失"。
- 单元：LLM / STT 服务用 fake client，断言 prompt 字段结构。
- API：`intake` 的 5 种响应分支；`confirm` 的成功、幂等、状态错、权限不足。
- 集成：录一段真实音频放 `tests/fixtures/voice/*.m4a`，用 pytest marker `@pytest.mark.llm_live` 跑真实链路，默认 skip，CI 手动触发。

### 9.2 前端

- Widget 测试：`VoiceRecordButton` 长按、上滑取消、超时自动停止。
- 集成：mock `VoiceService` 返回 5 种分支，断言跳转 / 撤销 / 弹窗行为。

### 9.3 金标集

`backend/tests/fixtures/voice_golden.jsonl`：每行 `{transcript, expected_intent, expected_fields}`。至少 30 条，覆盖：
- 驱虫 / 疫苗 / 体重 / 日常 / 未知 各 5 条以上
- 相对日期 / 绝对日期混合
- 多宠物场景（宠物名明确 / 模糊 / 缺失）
- 枚举缺失 / 完整
- 加备注 / 不加备注

CI 里跑 `extract_intent`，断言 intent 100% 命中、字段命中率 ≥ 90%。

---

## 10. 落地步骤（推荐顺序）

1. **打通交互骨架**：`intake` 接口先返回固定 stub JSON，前端跑通"录音 → 上传 → 按分支跳转 / 撤销"，验证 UX。
2. **接 STT**：音频 → 文字；同时把 `voice_intake_logs` 表和音频 MinIO 落地。
3. **接 LLM**：先用一批手写 prompt + 10 条金标；跑通 `intent` 和 `dewormed_at` 抽取。
4. **字段扩展**：补全 vaccination / weight / routine 分支，扩金标集到 30+。
5. **5 秒撤销 + 设置开关**：把自动提交路径打磨扎实，默认开着开关做一周内部灰度。
6. **日志分析**：跑一批线上日志，回流到金标集，迭代 prompt。

---

## 11. 主要取舍

- **LLM 只做抽取不做执行**：多一跳 `confirm`，但避免脏数据。对日记这种"用户会回头翻"的产品最关键。
- **失败走 200 + status**：把"听不清"视为正常业务路径而非异常，让前端分流更简单；只有调用方真错了才 4xx。
- **日期由后端算**：LLM 算日期准确率不稳，且难调；受限枚举 + 后端解析可测可回归。
- **不引入端侧 STT**：延迟会更低，但离线模型中文多方言识别率差、包体积涨，得不偿失。后端 STT 也便于统一日志 / 成本控制。
- **音频 24h 清理**：保留足够长以支持撤销 + 复盘，但不长期持有用户语音，降低合规风险。
