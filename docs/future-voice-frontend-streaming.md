# Future Optimization — 前端 WebSocket 边录边传语音

> **状态**：未排期的优化方向。记录在案以便 Phase 2 后期或 Phase 3 评估时可以直接动工。
> **前置**：[`docs/phase2-step2-voice-intake.md`](phase2-step2-voice-intake.md) 所述的 Phase 2 Step 2 已上线（2026-04-23 当前实现）。

## 1. 背景

当前（2026-04-23）的 STT 链路：

```
[Flutter 端]                   [后端]                        [DashScope]
长按 → 录完整段 .wav
松手 → HTTP multipart ───────► /voice/intake
                                   │
                                   ├─ 读 bytes 进内存
                                   ├─ 上传 MinIO（审计/回落源）
                                   ├─ 内存字节推 WS ─────────► fun-asr-realtime (SG)
                                   │   recognition.start()
                                   │   send_audio_frame() ×N
                                   │   recognition.stop()    ◄──── 最终 transcript
                                   ├─ qwen-plus 意图抽取
                                   └─ 返回 draft
                             ◄──────
```

### 1.1 当前瓶颈拆解（3.1s 样本）

| 阶段 | 当前耗时 | 是否可省 |
|---|---|---|
| 用户录音 | 用户控制（1-30s） | 不可省 |
| HTTP multipart 上传（3MB/s 上行估） | 50-300ms | **可省**：边录边传时上传和录音重叠 |
| 后端 MinIO put | 100-200ms | 可并行（不阻塞 STT） |
| 后端 → DashScope WebSocket 建连 + start | 200-400ms | **可省**：录音开始时就建好 WS |
| 音频流喂给 DashScope | ≈ 录音时长（实时模型按 1× 消费） | **可省**：边录边喂，松手时已喂完 |
| DashScope 处理完最后一帧返回 sentence_end（last_package_delay） | 200-1500ms | 不可省 |
| qwen-plus | 2000-3000ms | 可并行：transcript 到齐就开始 |
| 其它（日志 / Redis / commit） | <200ms | 不重要 |

**理论最优**：松手到看到 transcript ≈ `max(last_package_delay, LLM)` ≈ **1.5-3s**（当前实测 p50 3.5s，包含 HTTP 上传 + MinIO + WS 建连 + 顺序调用 LLM）。

但真正**感知延迟大头**不是 STT，是 LLM——如果能把 LLM 也和 STT 流式交叠、甚至边说边出部分 transcript 就送给 LLM，理论可以做到"松手后 0.5-1s 就出结果"。这是方案 B 的真正价值。

## 2. 方案 B：前端直推 WebSocket

### 2.1 链路

```
[Flutter 端]                                    [后端]                    [DashScope]
按下 → 申请一个 intake_id + Nonce ─────────► POST /voice/intake/start
                                     ◄───────── { intake_id, ws_url, ticket }
                                                 │
                                                 └─ 记录 pending，5s 内无连接就 GC
按下 → 打开 WebSocket ───────────────────────► /ws/voice/intake?ticket=...
                                                 │
                                                 ├─ 验票 + 鉴权（复用 JWT）
                                                 ├─ 开 DashScope WS ─────► fun-asr-realtime
                                                 │                         recognition.start()
Record.startStream() ──► Uint8List frames
  (100ms PCM 块)
Uint8List → WebSocket.add() ─────────────────►   on_audio_frame
                                                 │  send_audio_frame(pcm)  ─►
                                     ◄──────────  on_event（中间结果） 可选推给前端
                                                                             ◄── 中间 partial
                                                                             ◄── sentence_end（最终）
松手 → WebSocket.close() 或 send "<EOS>" ──►   recognition.stop()
                                                 ├─ transcript 到齐
                                                 ├─ qwen-plus 意图抽取（顺序或流式）
                                                 └─ 向前端发 FINAL 消息
                                     ◄──────────  { draft, missing_fields, ... }
```

### 2.2 需要实现的模块

#### 后端

1. **`POST /voice/intake/start`**：申领 `intake_id` + 短期 ticket（用 JWT HMAC 签 30s），响应里带 `ws_url`。不走业务逻辑，秒级返回。
2. **`WS /ws/voice/intake`**：
   - FastAPI 原生支持 `@app.websocket("/ws/voice/intake")`。
   - 用 `starlette.websockets.WebSocket.headers` 取 `Sec-WebSocket-Protocol` 里的 ticket / 或者 query string。
   - 鉴权通过后开 DashScope WS，`for frame in websocket.iter_bytes(): recognition.send_audio_frame(frame)`。
   - 收到 EOF 或客户端 close → `recognition.stop()`；同时在 DashScope 返回 `sentence_end` 的 callback 里立刻 `await llm.extract_intent()`（不等前端询问）。
   - LLM 完成后通过 WebSocket 推 `{"type":"final", ...}`。
3. **中间 partial result 推流**（可选）：DashScope callback 里的 `on_event` 每次触发就 forward 给前端，前端边录边展示"咪咪…打…驱虫…"滚动字幕。UX 显著提升。

#### 前端

1. **`record: ^5.x`** 已经提供 `startStream(RecordConfig)`：返回 `Stream<Uint8List>`（16-bit PCM 原始帧）。
   - 但 `record` 的 stream 模式在 Android 上是 single-subscription，要么包 broadcast 要么在一处订阅。
   - 当前代码里已经有一个 `StreamSubscription<Amplitude>` 订阅 amplitude，要和 `startStream()` 分开 engine 实例。
2. **WebSocket 客户端**：`web_socket_channel`（或 `dio_web_socket`）。
   - 打开连接时带 ticket；失败立刻退化到当前 HTTP 路径（保底）。
   - 实现简单的应用层协议：`first frame = {"type":"audio_start", "format":"pcm16", "rate":16000}`，之后是二进制 PCM 帧，EOS 发 `{"type":"audio_end"}`，接收 `{"type":"partial", "text":...}` / `{"type":"final", ...}`。
3. **UI**：`VoiceRecordButton` 重构
   - `onLongPressStart` → 异步触发 `/voice/intake/start` 拿 ticket → 并行 open WebSocket + `record.startStream()`。
   - `onLongPressMoveUpdate` 维持上滑取消逻辑；取消时 WebSocket 发 `{"type":"cancel"}`，后端直接走 `cancel` 软删。
   - 录音中如果收到 `partial`，叠在 HUD 上滚动显示。
   - `onLongPressEnd` → 发 `audio_end` → 等 `final` → 回调 `onRecordComplete` 带 draft 直接去创建页（不再需要 HTTP 那一跳）。

### 2.3 改动面与估时

| 模块 | 新增 / 改动 | 估时 |
|---|---|---|
| `backend/app/services/stt.py` | 从"同步一次性 transcribe"拆出"streaming session 类"，给 WS handler 复用 | 4h |
| `backend/app/api/v1/voice.py` | 新增 `POST /start` + `WS /ws/voice/intake` 两个端点 | 3h |
| `backend/app/services/voice_intake.py` | `intake` 拆成 `start_session` / `finalize_session`，兼容 HTTP + WS 两种入口 | 4h |
| `backend/app/services/auth.py` | 短期 ticket 签发 / 校验（独立于 JWT refresh） | 1h |
| `frontend/lib/widgets/voice_record_button.dart` | 整体重构为流式 + 状态机 | 4h |
| `frontend/lib/services/voice_service.dart` | 新增 `intakeStream()`，HTTP 版本保留为回落 | 3h |
| Nginx / docker-compose | WS 升级头透传（`proxy_set_header Upgrade / Connection`，超时 60s） | 1h |
| 测试 | 新增 WS 集成测试（`httpx.AsyncClient` + `pytest-asyncio` 的 `WebSocketTestClient`） | 3h |
| **合计** | | **≈ 23h** |

### 2.4 风险 & 回落

1. **NAT / 企业网关拦 WebSocket**：少数移动网络会阻断长连接。前端**第一次连接失败**或**连接 >3s 没拿到 server hello** 时立刻降级到 HTTP `POST /voice/intake`。这条回落必须作为设计的第一级公民，不能事后加。
2. **DashScope 侧断线**：已有处理——`recognition.stop()` 的 `on_error` callback 抛 `SttUnavailableError`。WS handler 收到后给客户端发 `{"type":"error","code":"stt_failed"}`，客户端展示"识别失败，请重录"（和当前行为一致）。
3. **前端 WebSocket 生命周期**：Flutter 后台切出时 WS 会被系统 reap。录音中途被切出直接当作用户取消处理；录完成正在等 `final` 时被切出 → 后端仍然完成识别并写入 log，前端下次前台显示"上次语音已自动保存，查看？"。
4. **后端资源**：每个 WS 连接占一个 DashScope session 配额。新加坡 `fun-asr-realtime` 的并发限制要查最新文档；假设 ≥ 20 并发，对个人应用是宽裕的，但需要监控（`voice_intake_logs` 已能按分钟 group 统计，够用）。
5. **鉴权**：`WS /ws/voice/intake` 不能直接用 JWT（iOS 原生 WebSocket 无法自定义 header）。所以用 `POST /start` 换一次短期 ticket（query string 里带），后端内存存 TTL=30s 的 `{ticket: user_id}` 映射。

### 2.5 不做的事

- **不**把 qwen-plus 也挪到浏览器/端直连 DashScope——意图抽取需要读后端的宠物列表、用户时区、prompt 版本，端上做会把业务逻辑泄漏到客户端。
- **不**尝试 WebRTC / RTSP 等更"实时"的协议——DashScope 不支持，无收益。
- **不**合并 intake log 和 WS session state 到 Redis——现有 `voice_intake_logs` 表 + 内存状态机足够；引入 Redis 反而增加运维面。

## 3. 触发条件

什么时候真的要做方案 B？优先级从高到低：

1. **生产观测到 p50 感知延迟 > 5s 且用户投诉集中在"语音慢"** → 做。当前 p50 约 3.5s，体感尚可。
2. **FastAPI + DashScope 组合出现稳定突发抖动**（如 SG realtime 队列再次塌陷）→ 做，顺带加 partial-result 展示作为"STT 还在工作"的视觉反馈，避免用户以为卡死。
3. **Phase 3 计划加"长语音留言 / 音频日记"功能**（单条 > 30s）→ 必做，HTTP multipart 在更长音频上会撞上游上传 timeout。

## 4. 验收指标

落地后需要达到：

- **感知延迟 p50 ≤ 1.5s、p90 ≤ 3s**（松手 → 看到 transcript/draft）。
- **回落到 HTTP 路径的成功率 ≥ 99%**（WS 建连失败时）。
- **Partial result 展示覆盖率 ≥ 80% 的 intake 请求**（UX 指标，中间结果至少刷新一次）。
- 现有端到端测试（`tests/api/test_voice_intake.py`）在 HTTP 回落路径下全部通过，**WS 路径新增独立 test 文件**覆盖成功 / 取消 / 上游断线 / 鉴权失败四个核心场景。

## 5. 相关引用

- 当前实现：[`backend/app/services/stt.py`](../backend/app/services/stt.py) · [`frontend/lib/widgets/voice_record_button.dart`](../frontend/lib/widgets/voice_record_button.dart)
- STT 路径选型与基准：[`docs/phase2-step2-voice-intake.md §0.5.1`](phase2-step2-voice-intake.md)
- DashScope 实时 ASR 官方示例：[`docs/API_docs/实时语音识别.md`](API_docs/实时语音识别.md)
- 基准脚本：[`backend/scripts/stt_realtime_bench.py`](../backend/scripts/stt_realtime_bench.py)
