# 后续优化：把慢任务下沉到异步任务队列

> 状态：**待规划**（not scheduled）
> 触发来源：2026-04-22 上传卡顿事件的根因分析
> 相关提交：`aac10c4 Add learning signals to photo auto-assign (Option A)`
> 相关代码：`backend/app/api/v1/photos.py::_backfill_embedding`,
> `backend/app/services/pet_centroid.py::add_embedding`,
> `backend/app/services/embedding.py::embed_image`

## 背景

当前上传接口 `POST /api/v1/pets/{pet_id}/photos` 在提交事务后，通过 FastAPI `BackgroundTasks` 为每张照片挂一个 `_backfill_embedding` 任务。它会：

1. 调 DashScope 拿到 1152 维 embedding（`embed_image`，走 `asyncio.to_thread` 的阻塞 SDK）；
2. 在 Postgres 上做一次 `_find_near_duplicate` 的 pgvector 查询；
3. 写入 `pet_photo_embeddings`，并对 `USER_CORRECTED` 行做 source 升级。

`BackgroundTasks` 的本质仍然是**跑在当前 API 进程的事件循环和线程池里**，只是延迟到 response 发送之后执行。这意味着：

- 上传 backfill 会和同进程内的其它请求（如前端"选完图马上打 `/photos/classify`"）竞争同一个 `ThreadPoolExecutor` 和 DashScope 外部配额；
- 任务没有持久化：进程崩溃 / 容器重启 / DashScope 瞬时失败后，该照片就**永远没有向量**，下一次 classify 也看不到它；
- 重试策略只能在函数内手写；没有"死信队列"概念，观测也只能靠 app log grep。

2026-04-22 短期已经用以下三个治标改动拿掉"用户可见的慢"：

- **前端**：`_submit()` 取消在飞的 classify（`CancelToken`），避免同一用户自己造并发；
- **后端**：`embed_image` 加全局 `asyncio.Semaphore(DASHSCOPE_EMBEDDING_CONCURRENCY=3)` 限流；
- **后端**：启动时把默认线程池显式设为 `THREAD_POOL_SIZE=32`，不再受"2 核默认 6 线程"约束。

这些能撑到用户量 ~数千，但长期方向依旧是把慢任务**完全搬出请求路径**。

## 目标

1. 上传接口在提交事务并返回响应之后，**API 进程不再执行任何 DashScope 调用 / pgvector 查询**；
2. backfill 失败可自动重试，失败上限后进入死信队列（DLQ）以人工介入；
3. 未来的慢任务（图片内容审核、封面图生成、推送批处理、历史照片回填 embedding 等）全部走同一套队列，不再一人一个 `BackgroundTasks`；
4. 本地开发只需一条 `docker compose up` 就能把 worker 跑起来，不增加新同学的启动门槛。

## 候选方案

### A. `arq`（基于 Redis 的 async 任务队列）

- 原生 `asyncio`，和 FastAPI 的心智模型最贴；
- worker 只是一条 `arq app.jobs.worker.WorkerSettings` 命令；
- 复用现有 Redis（我们已经在用它存短信验证码、JWT 黑名单）。

### B. Celery + Redis

- 生态最成熟，监控工具（Flower / Prometheus exporter）齐全；
- 默认是多进程同步 worker，不过也能跑 `-P gevent`/`eventlet`；
- 对 async SQLAlchemy session / async DashScope 调用不是"一等公民"，需要写桥接。

### C. Dramatiq + Redis

- 中间重量级，API 比 Celery 简洁；
- async 支持比 arq 弱，但比 Celery 原生 `asyncio` 略强；

### D. 不引入新依赖：手写一个 Postgres 行级队列（`FOR UPDATE SKIP LOCKED`）

- 零新组件，运维最简单；
- 但要自己实现重试、可见性超时、死信队列、指标——相当于**写一个小 Celery**。风险是长期维护成本。

倾向：**方案 A（arq）**，理由是：

1. 当前代码路径几乎全是 `async def`，arq 不用额外桥接；
2. 我们的 `app.services.redis` 已经跑在 `redis.asyncio` 上，连接池可复用；
3. 上线第一版只需要一个 job `backfill_photo_embedding(photo_id)`，后续再加 job 不增加架构复杂度。

## 迁移步骤（实施时填细节）

1. 新依赖：`arq>=0.25`。
2. 新增 `backend/app/jobs/` 包：
   - `worker.py` — `WorkerSettings` 配置（Redis URL / 最大并发 / 重试策略）；
   - `photo_embedding.py` — `async def backfill_photo_embedding(ctx, pet_id, photo_id, source) -> None`，内容是现在 `_backfill_embedding` 的逻辑。
3. 入队：在 `photos.py` 的 `upload_photos` 里，把
    `background_tasks.add_task(_backfill_embedding, ...)`
   替换成
   ``await arq_pool.enqueue_job("backfill_photo_embedding", pet_id, photo.id, source)``。
   保留 `BackgroundTasks` 作为**降级路径**：当 `arq_pool` 入队失败（Redis 宕）时，回退到原内嵌执行，只打一条 WARN 日志。
4. Docker Compose：新增 `arq-worker` service，和 `fastapi` 共享镜像，仅 `command` 不同。
5. 监控：在 `health_check` 里加一个 `queue_depth` 指标，通过 `await redis.xlen(...)` 读出；Grafana 或者 cron 告警里盯着。
6. 测试：
   - 单测：`jobs/photo_embedding.py` 的纯函数版本保持在 `app/services/pet_centroid.py`，job 层只做"拉依赖 + 调用 + 失败重试"。单测复用现有 `test_pet_centroid.py` + `test_embedding.py`；
   - 集成测：用 `arq.worker.Worker.run_check()` 在测试进程内起一个 worker，和 FastAPI TestClient 配合验证"上传 → job 最终把 embedding 写进 DB"。

## 不做什么 / 范围边界

- **不下沉** `/photos/classify` 本身。用户在对话框里等结果，必须同步返回；它需要的也是"短平快"的优化（已经做了 Semaphore 限流），而非异步化。
- **不下沉** 语音转写 / LLM 意图抽取（Phase 2 Step 2）。那条链路现在从录音上传到 draft 返回只要几秒，用户在 sheet 里等，异步化会把"等待"变成"轮询"，UX 反而更差。
- **不引入** 分布式锁 / 跨 worker 排他控制。每个 photo 只会被入队一次；同一 photo 重复入队（罕见）走 `ON CONFLICT DO NOTHING` 即可。

## 触发"现在就做"的信号

任何一条命中就把本项列进下个 sprint：

1. DashScope p95 持续 >3s（`embedding region=singapore elapsed=...` 日志）；
2. 单用户一次上传批量 >5 张成为常态（Phase 2 Step 4 以后的"批量回填"场景）；
3. 出现第二个类似的异步慢任务（图片审核 / 公众号封面生成 / …）；
4. 事件：`_backfill_embedding` 的 `logger.exception` 在一周内 >5 次。

在那之前，当前的 **Semaphore + 前端 cancel + 显式线程池** 的组合已经把用户侧体感拉回"毫秒级进度 + 秒级响应"。
