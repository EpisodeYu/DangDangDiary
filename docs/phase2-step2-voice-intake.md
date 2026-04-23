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
- **全局规则 §媒体处理**：原文要求"照片先在前端做格式转换"。音频同理——Flutter 端直接录 AAC/M4A（由 `record` 包默认输出），后端只接受 `audio/m4a`、`audio/aac`、`audio/mpeg`、`audio/wav` 四种 MIME，其它拒收。
- **复用而非重写写入逻辑**：本步不新增业务表（`voice_intake_logs` 仅为审计日志），不绕过现有的权限校验。`confirm` 接口内部必须走 `services/health.py` 等同一层服务，权限（EDITOR 及以上）随 Phase 2 Step 1 的成员角色自动生效。
- **第三方服务**：STT 与 LLM **全部走 DashScope（百炼）**，两者都默认走**新加坡地域**（需要 `DASHSCOPE_API_KEY_SAG`）：STT 用 `fun-asr`、LLM 用 `qwen-plus` JSON mode；任一路径异常时自动回落到北京地域（`DASHSCOPE_API_KEY`）的 `paraformer-v1` / 同一个 `qwen-plus`。**不**再使用阿里云智能语音交互（NLS）的「录音文件识别极速版」，因此不需要 `ALIYUN_STT_APP_KEY`。参考：[docs/API_docs/录音文件识别.md](API_docs/录音文件识别.md)。

---

## 0.5 模型选型与成本（Phase 2 补强）

> 本节用于定型具体模型版本与 SDK，避免实现期再二次决策。第一次对接前请务必把这里的模型名、SDK 版本、`.env` 键名（见 §8）全部落到 `config.py`。

### 0.5.1 STT：DashScope 新加坡 `fun-asr-realtime`（WebSocket 流式，主）+ 北京 `paraformer-v1`（async-file，回落）

- **选型历史（四次迭代）**：
  - **2026-04-19 首版**：`paraformer-realtime-v2` **同步文件模式**（`Recognition(callback=None).call`）。上线后 30s 音频端到端 7-60s+，频繁 "Idle timeout!"：实时模型按实时速度消费音频，且与在线会话共享队列。**教训：错在"实时模型 + 同步文件"这个组合，不是实时模型本身**。
  - **2026-04-20 修复**：切到 `Transcription.async_call` + **北京 `paraformer-v1`** 异步录音文件识别。30s 音频端到端稳定在 3-5s。
  - **2026-04-21 优化**：基准（`backend/scripts/stt_bench.py`，3.1s 样本 × N=10，Tokyo 服务器）显示跨境 TLS 握手是瓶颈——东京→`dashscope.aliyuncs.com` 握手 **3.2s**，p50 6.3s；切到新加坡 `fun-asr`（async-file）后 p50 **2.6s**、p90 4.3s。定型为 SG `fun-asr` 主 + BJ `paraformer-v1` 回落。
  - **2026-04-23 重新定型**：生产观测到 SG `fun-asr` async-file 队列严重退化（`task_status=PENDING` 10-30s 起步，100% 撞 12s 超时上限，`stt_failed` 成了常态）。重新基准，同时首次评估之前从未真正测过的 **WebSocket 流式路径**（2026-04-19 被否掉的是同步文件模式，不是 WebSocket 模式本身）：

    | 方案 | N | 成功率 | p50 | p90 | max | 备注 |
    |---|---|---|---|---|---|---|
    | **SG `fun-asr-realtime` WS 流式（主）** | 10 | 10/10 | **1.26s** | **1.59s** | **1.61s** | 无尾延迟 |
    | NLS FlashRecognizer 深圳 URL | 10 | 10/10 | 2.54s | 3.71s | 4.59s | 当日稳，但 ISI 独立运维 |
    | NLS FlashRecognizer 北京 URL | 5 | 5/5 | 3.29s | 4.48s | 5.18s | |
    | BJ `paraformer-v1` async-file（回落） | 3 | 3/3 | 4.14s | 6.53s | 7.13s | |
    | BJ `paraformer-realtime-v2` WS 流式 | 3 | 3/3 | 19.1s | 38.0s | 42.7s | 跨境 WS 延迟高 |
    | BJ `fun-asr-realtime` WS 流式 | 5 | 5/5 | 8.41s | 18.2s | 21.6s | 跨境 WS 延迟高 |
    | **SG `fun-asr` async-file（原主，弃）** | 3 | **0/3** | — | — | **>180s** | 队列堵塞 |
    | NLS FlashRecognizer 上海 URL | 5 | 3/5 | 7.36s | 22.3s | 26.1s | 2× ConnectTimeout |
    | NLS FlashRecognizer 深圳 二进制上传 | 5 | 4/5 | 7.00s | 12.0s | 13.1s | 1× ConnectTimeout |

    **定型**：SG `fun-asr-realtime` WebSocket 流式为主；BJ `paraformer-v1` async-file 保留为兜底。实时模型在 SG 路径上跑得反而比 async-file 快一个数量级，因为 realtime 池子和 batch 队列物理隔离，不会被 async 队列的堆积拖慢。

- **为什么不用 `qwen-audio-asr`**：把 STT 和语义理解揉在一个大模型里，单价贵一个数量级（≈ ¥0.06/30s），且与"STT 转文字 / `qwen-plus` 独立做结构化抽取"的分层架构重复付费；分层也让金标集可分别回归。
- **为什么不切到阿里云 NLS「录音文件识别极速版」（FlashRecognizer）**：2026-04-23 基准显示它比当前 SG realtime 路径慢一倍（p50 2.54s vs 1.26s），且 ISI 是独立产品线——需要维护 NLS 项目、24h Token 轮换、AppKey、独立计费。收益不抵运维成本。作为**第二兜底**可以记住，若 BJ async 也塌了再考虑接入。
- **为什么不用 BJ `paraformer-realtime-v2` WS 流式**：2026-04-23 基准 p50 19.1s / max 42.7s，跨境 WS 抖动远高于 SG 路径；且 SG 没有 `paraformer-realtime-v2`（国际区只提供 `fun-asr-realtime`），两边模型不能互为热备。
- **调用方式**（主路径）：`dashscope.audio.asr.Recognition(model='fun-asr-realtime', format='pcm', sample_rate=16000, callback=...)` → `recognition.start()` → 按 3200B（100ms）分块 `send_audio_frame(pcm_chunk)` → `recognition.stop()` 阻塞到 server 返回 `is_sentence_end=True`。后端在 `asyncio.to_thread` 里包一层，外层用 `asyncio.wait_for(timeout=6)` 兜底超时。音频走**后端内存直推**，不经 MinIO；MinIO 仍然写一份用作审计日志 + async-file 回落时的 presigned URL 源。实现见 [`backend/app/services/stt.py`](../backend/app/services/stt.py)。
- **调用方式**（回落路径）：`Transcription.async_call(model='paraformer-v1', file_urls=[presigned_url])` → `Transcription.wait(task=task_id)` → `httpx.get(transcription_url)`。12s 超时上限（由 `asyncio.wait_for` 拦截，SDK 自身的 `Transcription.wait` 不支持 timeout）。
- **支持格式**：主路径要求 16-bit 单声道 PCM WAV @ 8k/16k（stdlib `wave` 解析），不符合的格式（m4a / aac / mp3 / 多声道）自动落到回落路径。Flutter `record` 默认已经是 16k 单声道 WAV，主路径 100% 命中。
- **限制**：前端硬限 ≤ 30s + ≤ 2MB；realtime API 对长度无硬限制，本场景足够。
- **地域**：主路径用**新加坡** key（`DASHSCOPE_API_KEY_SAG`，endpoint `wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference`，模型 `fun-asr-realtime`）；回落用**北京** key（`DASHSCOPE_API_KEY`，endpoint `dashscope.aliyuncs.com/api/v1`，模型 `paraformer-v1`）。LLM + 多模态 embedding 继续按 §0.5.2 配置，不共用。
- **基准脚本**：
  - 异步文件路径 + FlashRecognizer：`backend/scripts/stt_bench.py`
  - WebSocket 流式路径：`backend/scripts/stt_realtime_bench.py`（2026-04-23 新增）
- **单次成本**：realtime 按音频时长计价 ≈ ¥0.00015/秒（比 async 稍贵一点）≈ **¥0.0045 / 30s**；回落路径 ¥0.0024/30s。100 活跃用户 × 每天 3 条 ≈ ¥40/月。
- **后续优化**：当前实现仍然是"端录完整段音频 → 上传到后端 → 后端再推 WebSocket 给 DashScope"。理论最优是**前端边录边通过 WebSocket 推给后端（或直接推 DashScope）**，松手时 transcript 已经在手上，感知延迟 <500ms。方案设计见 [`docs/future-voice-frontend-streaming.md`](future-voice-frontend-streaming.md)，排期未定。

### 0.5.2 LLM：通义千问 `qwen-plus` @ 新加坡（主）/ 北京（回落）

- **为什么是 `qwen-plus`**：本步骤 prompt 受限、输出 JSON 字段固定，`qwen-plus` 在温度 0 下命中率足够（[金标集](#)回归 intent 100% 命中、字段命中 100%）。
- **为什么不切 `qwen-flash`**（虽然便宜又快）：2026-04-21 基准（`backend/scripts/llm_bench.py`，6 case × N=5 = 30 次调用）显示 `qwen-flash` avg 1.22s / p50 1.04s，比 `qwen-plus` 快 2×，但对 `N_days_ago:<n>` 这个 placeholder 模板有**稳定错误**：5/5 把字面量 `N` 替换成了真实数字（输出 `3_days_ago:3`）。要切 flash 需要先在 `_parse_date` 加兼容正则，待补。
- **为什么不切 `qwen3.6-plus`**：同批基准 avg 3.35s / p50 3.31s，比 `qwen-plus` 慢 40%，准确率同为 100%（无增益），且价格更贵。3.6 的优势在 agentic / 多模态推理，与本任务无关。
- **地域**：主路径用**新加坡** key（`DASHSCOPE_API_KEY_SAG`，endpoint `dashscope-intl.aliyuncs.com/compatible-mode/v1`），回落用**北京** key（`DASHSCOPE_API_KEY`，endpoint `dashscope.aliyuncs.com/compatible-mode/v1`）。同一个 `qwen-plus` 模型在两个 region 的输出等价，选型驱动纯粹是东京→北京 TLS 握手 ≈ 3.2s 的跨境成本：相同 prompt 实测 BJ p50 **4.38s** / max 9.39s（高抖动），SG p50 **2.32s** / p90 2.51s（几乎无抖动）。切 SG 直接砍掉了 LLM 阶段约 2s 延迟。实现见 [`backend/app/services/llm.py`](../backend/app/services/llm.py) 的 `_regions_in_priority_order()`：SG 返回 `OpenAIError` / 网络异常时自动一次性回落到 BJ（`malformed json` 不回落，直接外抛）。
- **调用通道**：`openai.AsyncOpenAI` 直打 DashScope OpenAI 兼容接口（不用 `dashscope` SDK 打 LLM）。与未来多模态 embedding（[phase2-step3](phase2-step3-photo-auto-assign.md)）共用一套客户端。
- **JSON mode**：`response_format={"type": "json_object"}` + §5 system prompt，严格 JSON 输出。
- **参数**：温度 0，top_p 1，`max_tokens=300`，`seed=42`（便于复现金标集回归）。
- **单次成本**：输入 ≈ 300 tokens、输出 ≈ 80 tokens，按 qwen-plus 定价（输入 0.0008 元/千、输出 0.002 元/千） ≈ **¥0.0004 / 次**。
- **`TONGYI_MODEL` 环境变量**：代码里**不要硬编码** `qwen-plus`，全部从 `settings.TONGYI_MODEL` 读。未来补了 `_parse_date` 的 `\d+_days_ago` 兼容后切 `qwen-flash`，改 `.env` 一行即可。

### 0.5.3 单次语音记录总成本

| 环节 | 成本 |
|---|---|
| MinIO 存储（24h 即删） | ≈ 0 |
| DashScope STT（SG `fun-asr-realtime` 主 / BJ `paraformer-v1` 回落） | ≈ ¥0.0045 |
| DashScope `qwen-plus` | ≈ ¥0.0004 |
| 后端 CPU/内存 | 忽略 |
| **合计** | **≈ ¥0.005 / 次** |

> 低成本也意味着可以把"识别失败自动重录"纳入 UX 而不担心费用击穿。

---

## 1. 整体链路

```
长按录音 (Flutter)
    │  松手
    ▼
上传音频 multipart  ──►  POST /api/v1/voice/intake
                            │
                            ├─ STT (DashScope SG fun-asr-realtime WS 主 / BJ paraformer-v1 async 回落) → transcript
                            ├─ LLM (DashScope qwen-plus, JSON mode)         → {intent, fields, confidence}
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
3. **STT**：`services/stt.py`（SG `fun-asr-realtime` WebSocket 流式主 + BJ `paraformer-v1` async-file 回落）；主路径抛 `SttUnavailableError` 或 6s 超时时自动落回落；全部失败 → `stt_failed`。
4. **LLM**：`services/llm.py`（新建，走 DashScope OpenAI 兼容端点调 `qwen-plus`，强 JSON mode），prompt 见 §5；超时 8s，失败 1 次重试。
5. **归一化**（`_normalize_draft`）：
   - 相对日期："今天/昨天/上周三" → 按服务器 UTC + 用户 profile 的时区解析为 `date`；**绝不让 LLM 自己算日期**。
   - 宠物解析：LLM 输出 `pet_name`（字符串），后端在当前用户 `pets` 列表里做精确 → 模糊匹配；多候选或无匹配时置 `pet_id=null`、加入 `missing_fields`；`default_pet_id` 仅在 LLM 未给出 `pet_name` 时兜底。
   - 枚举（`deworming_type`、`vaccine_type` 等）：LLM 必须返回枚举值字面量（`internal` / `external` / `combined`），否则视为缺失。
6. **写 log**：`draft_pending` / `stt_failed` / `intent_unknown` 三种之一。
7. **返回结构体**。

### 4.2 `services/stt.py`、`services/llm.py`（新建）

- 薄封装，只暴露 `transcribe(audio_bytes: bytes, mime: str, audio_url: str) -> str` 和 `extract_intent(transcript: str, context: dict) -> dict`。
- 所有第三方 key 从 `config.py` 读 `.env`（`DASHSCOPE_API_KEY` = 北京，服务 LLM 回落 + embedding + STT 回落；`DASHSCOPE_API_KEY_SAG` = 新加坡，服务 STT 主路径 + LLM 主路径。不再有 `ALIYUN_STT_*` 或 `TONGYI_API_KEY`），符合全局规则。
- 单元测试通过 monkeypatch 注入 fake client 覆盖，不打真实网络。

#### 4.2.1 `services/stt.py` 参考实现

源码见 [backend/app/services/stt.py](../backend/app/services/stt.py)（`dashscope>=1.25`）。关键设计：

- **主路径（SG WebSocket 流式）**：`dashscope.audio.asr.Recognition(model='fun-asr-realtime', format='pcm', sample_rate=16000, callback=<on_event/on_error>)` → `recognition.start()` → 按 3200B（= 100ms@16kHz-16bit）分块 `send_audio_frame(pcm_chunk)` → `recognition.stop()` 阻塞到 server 返回句尾结果。`dashscope.base_websocket_api_url = 'wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference'`。
  - 只接受 16-bit 单声道 PCM WAV（stdlib `wave` 解析 + 校验），不符合的格式自动落回落路径；Flutter `record` 默认输出就是 16k 单声道 WAV，主路径 100% 命中。
  - 在 `asyncio.to_thread` 中执行同步 SDK 调用；外层 `asyncio.wait_for(timeout=6)` 兜底超时（p90 1.59s，6s 足够吸收任何一次网络抖动）。
  - 音频 bytes **不经 MinIO 落盘**到识别路径——`voice_intake.py` 已经把 `await audio.read()` 的结果缓存在内存里，直接传给 `stt.transcribe(audio_bytes=...)`。MinIO 仍然写一份用作审计日志 + 回落路径的 presigned URL 源。
- **回落路径（BJ async-file）**：`dashscope.audio.asr.Transcription.async_call(model='paraformer-v1', file_urls=[presigned_url], language_hints=['zh', 'en'])` → `Transcription.wait(task=task_id)` → `httpx.get(transcription_url)` 合并 `text`。`asyncio.wait_for(timeout=12)` 兜底超时（SDK 的 `Transcription.wait` 本身不支持 timeout）。
- 基准复测脚本：
  - WebSocket 流式：`backend/scripts/stt_realtime_bench.py`
  - 异步文件 + FlashRecognizer：`backend/scripts/stt_bench.py`

> 离线单元测试：voice_intake 测试链路 monkeypatch `voice_intake_service.stt_transcribe` 这一层，不需要打 dashscope 真实网络。如要测 `stt.py` 内部的回落逻辑，monkeypatch `_transcribe_realtime_sync` / `_transcribe_async_sync` 按分支返回不同结果。

#### 4.2.2 `services/llm.py` 参考实现

源码见 [backend/app/services/llm.py](../backend/app/services/llm.py)。关键设计：

- 用 `openai.AsyncOpenAI` 直打 DashScope **OpenAI 兼容端点**（不用 `dashscope` SDK）。与 [phase2-step3](phase2-step3-photo-auto-assign.md) 的 embedding 客户端同源。
- 两个 region 按优先级串行重试，与 STT 的 `_regions_in_priority_order()` 对称：
  1. **新加坡（主）**：`api_key = settings.DASHSCOPE_API_KEY_SAG`，`base_url = 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1'`
  2. **北京回落**：`api_key = settings.DASHSCOPE_API_KEY`，`base_url = 'https://dashscope.aliyuncs.com/compatible-mode/v1'`
- `extract_intent(transcript, *, known_pet_names, default_pet_name, today) -> dict`：SG 抛 `OpenAIError` 或其他异常时**自动换 region 重试**；所有 region 失败 → `LlmUnavailableError`。`malformed json` 情况**不回落**（模型本身返回坏 JSON，换区也没用），直接外抛以免浪费用户另一秒。
- 生成 prompt 时把用户宠物列表作为**闭集**传入（`known_pet_names`），让 qwen-plus 自己做同音字矫正（STT 常把「咪咪」听成「米米」，在 LLM 侧就近映射比后端做 fuzzy match 鲁棒）。
- 生成 prompt 时**必须**把 `today`（服务端当日）写进 user message（格式「当前日期：YYYY-MM-DD（星期X）」）。这是 **prompt v2** 的关键修复：v1 依赖"LLM 只吐 today / yesterday / N_days_ago 快捷写法"的约定，但遇到「上个月 8 号 / 上周三 / 两周前」这种无法用快捷写法表达的相对日期时，LLM 会被迫退化到 `YYYY-MM-DD`；在没有日期锚点的情况下它会从训练先验里幻觉一个日期（实测 2026-04-21 问"上个月 8 号"→ `2024-05-08`）。v2 起允许 LLM 自己把相对日期换算成 `YYYY-MM-DD`，同时 `_parse_date` 加了「不晚于今天 & 不早于 10 年前」的兜底。
- 成功时在返回 dict 里塞一个 `_raw` 字段，调用方把原始字符串落到 `voice_intake_logs.llm_raw` 用于 prompt 迭代审计（`voice_intake_service` 会把它 pop 掉后再返回给客户端）。
- 参数：`temperature=0, top_p=1, max_tokens=300, seed=42, response_format={"type": "json_object"}`，`model = settings.TONGYI_MODEL`（默认 `qwen-plus`）。

> 离线单元测试：voice_intake 测试链路 monkeypatch `voice_intake_service.llm_extract_intent` 这一层即可，不打真实网络。如需测 region 回落分支，monkeypatch `openai.AsyncOpenAI` 的构造器或 `chat.completions.create` 按 `base_url` 返回不同结果。

---

## 5. LLM Prompt 设计

JSON mode + 严格 schema。系统提示词要点：

```
你是一个宠物日记的信息抽取助手。用户会说一句中文，你必须输出 JSON，字段如下：
{
  "intent": "deworming" | "vaccination" | "weight" | "routine" | "unknown",
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
1. 日期字段输出规范：
   - 「今天」→ "today"；「昨天」→ "yesterday"；「前天 / N 天前」→ "N_days_ago:<n>"。
   - 其它相对表达（「上个月 8 号」「上周三」「两周前」等）必须基于 user 消息里给出的「当前日期」换算为 "YYYY-MM-DD"；禁止无锚点猜日期。
   - 输出的 YYYY-MM-DD 不得晚于「当前日期」。
2. 只要一个字段你没有明确听到，就返回 null；禁止猜测。
3. 如果这句话不是在记一件宠物相关的事，intent 直接返回 "unknown"，其余字段 null。
4. 只输出 JSON，不要解释。
```

- 温度 0，top_p 1。
- user message 首行固定追加「当前日期：YYYY-MM-DD（星期X）」，作为所有相对日期换算的锚点；缺了这一行 qwen-plus 对「上个月 8 号」等表达会从训练先验里幻觉日期（v1 → v2 修复点）。
- prompt 版本号随 log 一起存，便于 A/B。
- 上线前备一份金标集（20-30 条典型语句 × 预期 JSON），在 CI 里跑 `llm.extract_intent` 的离线回归——允许轻度偏移，但 `intent` 必须 100% 命中。

### 5.1 关于 `photo_note` 意图（已下线）

> 历史版本的 prompt 里有 `photo_note` 枚举，意图是"顺便给照片加一句语音备忘"。实际走通链路时发现：
> 1. 语音入口拿不到照片引用（没有 `photo_id` 上下文），落不了库；
> 2. 用户如果想给某张照片加备注，更自然的路径是在照片详情页文字输入。
>
> **决策**：从 prompt 的 `intent` 枚举里**删掉 `photo_note`**；模型只输出 `deworming / vaccination / weight / routine / unknown` 五选一。
> 如果未来做出"照片 + 语音备忘"的组合入口（例如录音时已选中某张照片），应作为**新 intent** 独立开发、独立金标集回归，不复用本步骤的抽取管道。

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
- `.env` 变量与申请入口（值由运维配置；`.env.example` 只放占位符）：

| 键名 | 必填 | 默认值 | 现状 | 申请 / 获取入口 |
|---|---|---|---|---|
| `DASHSCOPE_API_KEY` | 是 | — | ✅ 已配置 | 北京地域 key。[bailian.console.aliyun.com](https://bailian.console.aliyun.com/?tab=model#/api-key)（**不是** modelstudio 子站）→ API Key 管理。服务：LLM 回落、STT 回落（`paraformer-v1` async-file）、`multimodal-embedding-v1`（[phase2-step3](phase2-step3-photo-auto-assign.md)）。 |
| `DASHSCOPE_API_KEY_SAG` | 是（推荐） | — | ✅ 已配置 | 新加坡地域 key。[modelstudio.console.aliyun.com](https://modelstudio.console.aliyun.com/?tab=dashboard#/api-key) → API Key 管理。服务：STT 主路径（`fun-asr-realtime` WebSocket 流式）、LLM 主路径（`qwen-plus`）。未配置时两者都只剩北京路径，STT p50 从 1.3s→4.1s、LLM p50 从 2.3s→4.4s 退化（见 §0.5.1 / §0.5.2 基准）。 |
| `DASHSCOPE_BASE_URL` | 否 | `https://dashscope.aliyuncs.com/compatible-mode/v1` | 默认 | 北京 OpenAI 兼容端点。LLM 回落 + embedding 使用。 |
| `DASHSCOPE_BASE_URL_SAG` | 否 | `https://dashscope-intl.aliyuncs.com/compatible-mode/v1` | 默认 | 新加坡 OpenAI 兼容端点。LLM 主路径使用。 |
| `TONGYI_MODEL` | 否 | `qwen-plus` | 默认 | 可切 `qwen-max` / 带日期的快照版做灰度。 |

> STT 的 endpoint / model 名不暴露为 env 键——主路径是 WebSocket（`wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference`，`fun-asr-realtime`），回落是 HTTP（`https://dashscope.aliyuncs.com/api/v1`，`paraformer-v1`），协议不同、不能用同一个 knob 交换，硬编码在 [backend/app/services/stt.py](../backend/app/services/stt.py)。要改模型 / endpoint 直接改代码。
| `VOICE_INTAKE_MAX_SECONDS` | 否 | `30` | 默认 | 前后端各自自限 |
| `VOICE_INTAKE_MAX_MB` | 否 | `2` | 默认 | m4a 压缩后 30s 一般 < 500KB，留 4× 余量 |
| `VOICE_AUDIO_TTL_HOURS` | 否 | `24` | 默认 | MinIO 生命周期策略对齐此值 |

> **已废弃的键**（如果 `.env` 里残留请删除，代码里也不要再 import）：
> - `ALIYUN_STT_APP_KEY`、`ALIYUN_STT_REGION`、`ALIYUN_STT_ACCESS_KEY_ID/SECRET`（NLS 方案已下线）
> - `TONGYI_API_KEY`（用 `DASHSCOPE_API_KEY` 替代）
>
> `ALIYUN_ACCESS_KEY_ID` / `ALIYUN_ACCESS_KEY_SECRET` **继续保留**，但仅服务于 Phase 1 的 `RecognizeScene`（现已默认关闭，见 `ENABLE_SERVER_PET_RECOGNITION`）和短信验证码，不服务于语音识别。

- 首次配置步骤备忘（运维侧）：
  1. **百炼北京**（[bailian.console.aliyun.com](https://bailian.console.aliyun.com/)）开通：「通义千问」「录音文件识别 Paraformer（async-file）」「多模态向量 multimodal-embedding-v1」。记 key 到 `.env` 的 `DASHSCOPE_API_KEY`。
  2. **百炼新加坡**（[modelstudio.console.aliyun.com](https://modelstudio.console.aliyun.com/)，是**另一个域名/账号视图**）开通：「Fun-ASR 实时语音识别（realtime WebSocket）」。记 key 到 `.env` 的 `DASHSCOPE_API_KEY_SAG`。两个 key 同一个阿里云主账号，计费独立账单合并。
  3. 在 MinIO 新建 `voice-intake` bucket，挂 24h 生命周期规则。
  4. 后端 `requirements.txt` 确保含 `dashscope>=1.25` 与 `openai>=1.40`，随 `docker compose build` 自动安装（**开发者本地不需要 `pip install`**）。

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

**首批 10 条示例（复制到 `voice_golden.jsonl` 作起点，实现前务必人工复核一遍）**：

```jsonl
{"transcript":"今天给咪咪做了驱虫","expected_intent":"deworming","expected_fields":{"pet_name":"咪咪","dewormed_at":"today","deworming_type":null,"note":null}}
{"transcript":"昨天橘子打了狂犬疫苗","expected_intent":"vaccination","expected_fields":{"pet_name":"橘子","vaccinated_at":"yesterday","vaccine_name":"狂犬","note":null}}
{"transcript":"三天前给狗子称了下体重六点二公斤","expected_intent":"weight","expected_fields":{"pet_name":"狗子","weighed_at":"N_days_ago:3","weight_kg":6.2,"note":null}}
{"transcript":"刚才给小白洗了个澡","expected_intent":"routine","expected_fields":{"pet_name":"小白","routine_at":"today","routine_type":"bath","note":null}}
{"transcript":"上午遛了花花半小时","expected_intent":"routine","expected_fields":{"pet_name":"花花","routine_at":"today","routine_type":"walk","note":"半小时"}}
{"transcript":"今天做了体内外同驱","expected_intent":"deworming","expected_fields":{"pet_name":null,"dewormed_at":"today","deworming_type":"combined","note":null}}
{"transcript":"嗯今天天气不错适合遛狗","expected_intent":"unknown","expected_fields":{"pet_name":null,"routine_at":null,"routine_type":null,"note":null}}
{"transcript":"帮我订一下明天的早餐","expected_intent":"unknown","expected_fields":{"pet_name":null,"note":null}}
{"transcript":"猫猫打了三联疫苗体内驱虫也做了","expected_intent":"vaccination","expected_fields":{"pet_name":"猫猫","vaccinated_at":"today","vaccine_name":"三联","note":"体内驱虫也做了"}}
{"transcript":"五月一号给二哈做的外驱","expected_intent":"deworming","expected_fields":{"pet_name":"二哈","dewormed_at":"2026-05-01","deworming_type":"external","note":null}}
```

**说明**：
- "猫猫打了三联疫苗体内驱虫也做了"属于**一句话两件事**，模型只抽主 intent（疫苗），次要事件回 `note` 字段；不做多 intent 拆分。若未来确需拆分，走 §5.1 的"新 intent / 新管道"路线，不复用本管道。
- 第 10 条的 `2026-05-01` 是相对于今天（2026-04-20，见项目文档顶部）的绝对日期口述，测试时可按当前日期替换或用 freezegun 冻结时间。

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
