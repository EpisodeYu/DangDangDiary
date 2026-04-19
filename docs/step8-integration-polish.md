# Step 8：源码优化与自动化测试

> 本文替换原「Step 8 整合调试与 UI 打磨」。
>
> Phase 1 的 UI 打磨（配色 / 圆角 / 动效 / SnackBar 统一 / 空状态样式等）**全部推迟到 Phase 2 收尾阶段**统一处理。原因：产品尚未上线，没有真实用户反馈之前做精细化 UX 优化收益低，而稳定性与高并发准备直接决定上线可行性。
>
> **前置依赖**：Step 1–7 代码与文档已按实际实现对齐。

---

## §0 背景与范围

### 目标
1. **源码鲁棒性 / 可读性 / 架构合理性**升级，为后续「千级用户 + 高并发」上线做准备。
2. **自动化测试体系**重构：补齐覆盖率缺口、拆分过大用例、清零告警、引入与生产一致的 Postgres 集成层。

### 非目标（Phase 1 不做）
- 任何 UI / UX 打磨（配色、字体、圆角、阴影、骨架屏、动画、空状态插画等）。
- 新业务功能。
- 重型基础设施迁移（K8s、读写分离、分片）——留到 Phase 2 根据真实负载再决定。

### 刚性约束
- **不能破坏现有功能**：每项重构前必须先有对应的自动化测试，测试通过后再改实现代码。
- **分任务、小步走**：本文档不是一次性大 PR，而是把 P0/P1/P2 条目拆成可独立提交的小任务池。每条都有「动作 → 文件 → 验收」。
- **向前兼容**：数据库迁移可增不可减；API schema 字段只增不删；前端 / 后端互相兼容旧客户端至少一个发布周期。

### 执行节奏（建议）
1. 先把 §2 的测试先补齐（尤其是缺口模块：pets / photos / routines）——给后续重构提供安全网。
2. 再做 §1 的 P0 条目（阻塞 I/O、索引、datetime、api_client 单飞）。
3. 最后做 P1（架构抽象）与 P2（收尾）。

---

## §1 源码优化

### §1.1 主题分组（跨模块的 12 条优化原则）

每条按「现状 → 目标 → 验收」描述，引用具体文件 / 函数。

#### 1) 数据库连接池与会话管理
- **现状**：[`backend/app/database.py`](backend/app/database.py) `create_async_engine(settings.DATABASE_URL, echo=settings.DEBUG)` 未配置连接池参数；`get_db()` 在没有异常时无条件 `await session.commit()`，对只读请求产生多余的事务提交。
- **目标**：
  - 引入 `pool_size=10, max_overflow=20, pool_pre_ping=True, pool_recycle=1800`（可通过 `.env` 覆写）。
  - 将 `echo` 与 `DEBUG` 解耦，新增 `DB_ECHO: bool = False`。
  - 去掉 `get_db()` 尾部的隐式 `commit`；Services 层凡是写操作必须显式 `await db.commit()`（或沿用现有 `flush` + 由路由尾部的 `commit` 统一提交，二选一并在文档中写死）。
- **验收**：
  - 单测 `tests/unit/test_db_session.py`：一个 GET 路由只触发 `SELECT`，事务不会出现 `COMMIT`（用 sqlalchemy event 监听）。
  - 在 PG 下压测 200 并发只读，无 `too many connections` / `pool timeout`。

#### 2) 核心表复合索引
- **现状**：[`backend/app/models/photo.py`](backend/app/models/photo.py) 等只在 `pet_id` 上建立单列索引；时间轴主查询 `ORDER BY taken_at DESC, created_at DESC, id DESC` 在大表上会退化为 filesort。
- **目标**：新增 Alembic revision，添加以下复合索引：
  - `photos(pet_id, taken_at DESC, created_at DESC, id DESC)`
  - `weights(pet_id, recorded_at DESC, created_at DESC, id DESC)`
  - `dewormings(pet_id, deworming_type, dewormed_at DESC, id DESC)`
  - `vaccinations(pet_id, vaccinated_at DESC, created_at DESC, id DESC)`
  - `routines(pet_id, routine_type, performed_at DESC, id DESC)`
  - `pet_members(user_id)`（时间轴内 `_resolve_accessible_pet_ids` 主查询路径）。
- **验收**：
  - Postgres 集成测试 `tests/integration/test_indexes.py`：`EXPLAIN` 主查询含 `Index Scan` 而非 `Seq Scan`。
  - 在 1 万条 photos 的样本集合下，timeline 首页 p95 响应 < 80 ms。

#### 3) 时间统一：替换 `datetime.utcnow()`
- **现状**：`utils/security.py`、`services/health.py`、`services/auth.py`、`services/pet.py`、`api/v1/photos.py`、所有 model `default=datetime.utcnow` 都使用 Python 3.12 已弃用的 `datetime.utcnow()`；pytest 会出大量 `DeprecationWarning`。
- **目标**：
  - 新增 `backend/app/utils/time.py`：`def utcnow() -> datetime: return datetime.now(timezone.utc).replace(tzinfo=None)`（保持列类型 naive，与现有 DB 列兼容）。
  - 所有业务代码与模型 default 统一改用 `utils.time.utcnow`。
- **验收**：`pytest -W error::DeprecationWarning` 无告警；`grep -rn "datetime.utcnow" backend/app` 为空。

#### 4) 阻塞 I/O：MinIO / Pillow 必须走线程池
- **现状**：[`backend/app/services/storage.py`](backend/app/services/storage.py) 的 `delete_photo_objects`、`delete_object_by_url`、`delete_objects_by_prefix`、`upload_pet_avatar`、`_ensure_bucket`、`_generate_thumbnail` 都是同步调用。`photos.py` 的上传路径已用 `asyncio.to_thread` 包装 `upload_photo`，但**删除路径没有**——高并发下会堵住事件循环。
- **目标**：
  - 为每个面向外部（async 调用方）的 storage 函数提供 async 版本：`async def adelete_photo_objects(...)`、`async def adelete_object_by_url(...)`、`async def adelete_objects_by_prefix(...)`、`async def aupload_pet_avatar(...)`。内部保留同步版本不改。
  - 调用方（`api/v1/photos.py` 的 delete、`services/pet.py` 的 delete_pet/upload_avatar）全部改用 async 版本。
  - `_ensure_bucket` 改为在 FastAPI `lifespan` 里一次性初始化所有 bucket，后续请求跳过。
- **验收**：
  - 新增 `tests/api/test_photos.py` 中 `delete_photo` 用例断言事件循环在调用期间不被阻塞（通过并发请求完成时间差）。
  - `grep` 业务代码中 `service/storage.py` 内部函数被 async handler 直接调用的地方为 0。

#### 5) 鉴权 Dependency 瘦身
- **现状**：[`backend/app/dependencies.py`](backend/app/dependencies.py) 的 `get_current_user` 每个请求都执行 `SELECT users WHERE id=?`，造成 1 次额外的 DB roundtrip。
- **目标**：
  - 拆分成两个 dependency：
    - `get_current_user_id() -> int`：仅解码 JWT，不查库。默认鉴权。
    - `get_current_user() -> User`：保留原行为，只在真正需要 User 对象的接口（如 `PUT /auth/me`）使用。
  - 路由逐个迁移到 `get_current_user_id`（`api/v1/pets.py`、`api/v1/photos.py`、`api/v1/health.py`）；Service 层签名同步从 `current_user: User` 改为 `user_id: int`。
- **验收**：
  - 以一个已登录 token 调用 `GET /pets`，断言只触发 `SELECT pet_members / pets`，不触发 `SELECT users`（sqlalchemy event 监听）。
  - 所有 API 测试保持绿色。

#### 6) 启动安全自检
- **现状**：[`backend/app/config.py`](backend/app/config.py) 有默认值 `JWT_SECRET_KEY="your-secret-key-change-in-production"`、默认 MinIO 口令 `minioadmin123`、`PUBLIC_BASE_URL="http://YOUR_SERVER_IP"`。
- **目标**：在 `main.py` 的 `lifespan` 启动时执行 `assert_production_safe(settings)`：
  - 当 `DEBUG=False` 时，以下任意一项为默认值即 `RuntimeError`：`JWT_SECRET_KEY`、`MINIO_SECRET_KEY`、`ALIYUN_ACCESS_KEY_ID`、`ALIYUN_ACCESS_KEY_SECRET`、`PUBLIC_BASE_URL`。
  - 将 `JWT_SECRET_KEY` 的强度检查（长度 ≥ 32、非字典词）作为 `DEBUG=False` 下的 warning（不阻塞启动）。
  - **`DEBUG=True` 完全静默**（Q4 决定，开发零摩擦）：函数立即 `return`，既不抛异常也不打任何日志/warning，保证 dev 与 test 环境启动输出干净。
- **验收**：
  - 单测 `tests/unit/test_config_guard.py` 对默认 `.env` 在 `DEBUG=False` 下启动抛 `RuntimeError` 且 `code` 精确到出错字段。
  - 同一单测用 `caplog` 捕获 `DEBUG=True` 启动过程：`logging.getLogger('app.config')` 无任何 `WARNING` / `ERROR` 级别记录。

#### 7) Refresh Token 黑名单键换成 `jti`
- **现状**：[`backend/app/services/redis.py`](backend/app/services/redis.py) 以整串 JWT 作为 Redis key（`auth:refresh:blacklist:{token}`），key 长度 ~ 200+ 字节，Redis 内存浪费；也无法在未来做批量撤销（按用户 / 按设备）。
- **目标**：
  - [`backend/app/utils/security.py`](backend/app/utils/security.py) 在 `create_refresh_token` 里加入 `jti`（`secrets.token_urlsafe(16)`）。
  - 黑名单键改为 `auth:refresh:jti:{jti}`，ttl 沿用 token 剩余生命期。
  - `auth_service.refresh_access_token` / `logout` 读 `jti` 做判定。
  - `decode_token` 对 refresh 类型强制要求 `jti` 字段存在；**无 `jti` 直接视为 `INVALID_REFRESH_TOKEN` 401**——老 token 立即失效。
- **切换方式（Q3 决定：立即切换）**：
  - 当前项目处于个人测试阶段，不涉及外部用户；直接发新版后端即可。
  - 新版上线后，老格式 refresh token 因无 `jti` 被服务端拒绝；客户端现有 [`frontend/lib/services/api_client.dart`](frontend/lib/services/api_client.dart) 在 `/auth/refresh` 401 时已会触发 `onForceLogout`，测试账号重新登录即可。
  - 可选：跑一次性脚本 `backend/scripts/flush_legacy_refresh_blacklist.py`（`SCAN MATCH auth:refresh:blacklist:*` + `UNLINK`）释放 Redis 里的老黑名单 key；本地开发 Redis 也可直接 `FLUSHDB`。
- **验收**：
  - `tests/api/test_auth.py` 新增：老格式 refresh token（payload 无 `jti`）调 `/auth/refresh` → 401 `INVALID_REFRESH_TOKEN`；调 `/auth/logout` 亦 401。
  - 新格式 token 正常 refresh / logout / 再 refresh（第二次返回 401）链路全绿。
  - 清理脚本 dry-run 输出待删除 key 数量；正式 run 后 `SCAN auth:refresh:blacklist:*` 返回空。

#### 8) 日志、请求 ID 与结构化输出
- **现状**：`main.py` 没有 access log / request id；大量 `except Exception: pass`（storage.py）静默吞掉 MinIO 异常；alembic.ini 的 log level `WARN`。
- **目标**：
  - 新增 `backend/app/utils/logging.py`：基于 stdlib logging 的 JSON formatter，字段 `ts, level, logger, request_id, method, path, status, duration_ms, message`。
  - `main.py` 注册中间件 `RequestIdMiddleware`（从 `X-Request-ID` header 读，缺省生成）+ `AccessLogMiddleware`。
  - 把 storage.py 所有 `except Exception: pass` 改为 `except Exception as e: logger.warning(...)`，把 `exceptions.AppException` 不覆盖原始堆栈。
- **验收**：
  - 一次正常请求的日志 JSON 解析通过，且有 request_id 对应关系。
  - `tests/unit/test_logging.py` 断言 request id 在路由处理函数的 context 中可读（存进 `contextvars`）。

#### 9) CORS / IP 级限流
- **现状**：无 CORS 中间件；登录接口只有按手机号的 60 秒限流，没有 IP 级限流，容易被撞库。
- **目标**：
  - 加 `CORSMiddleware`，白名单从 `settings.CORS_ORIGINS`（`.env` 列表）读入；Phase 1 默认 `["http://localhost", "app://dangdang"]`。
  - 引入 `slowapi` 或自实现 Redis 令牌桶：对 `/auth/send-code`、`/auth/login`、`/auth/refresh` 按 IP 限流（例如 10 次/分）。
- **验收**：`tests/api/test_rate_limit.py` 对同一 IP 连续 11 次登录请求，第 11 次返回 429。

#### 10) 上传幂等 `Idempotency-Key`
- **现状**：网络不稳时前端重传可能导致服务器存在双份照片；同日上传同一张图但被识别为两张记录。前端 `_RetryInterceptor` 虽然主动跳过 `FormData` 自动重试，但用户手动点「重试」仍会产生重复。
- **目标（Q2 决定：Phase 1 完整落地，含前端持久化）**：
  - **前端（含持久化）**：
    - [`frontend/lib/services/photo_service.dart`](frontend/lib/services/photo_service.dart) 在准备上传前，为每个文件计算稳定的 `local_key = sha1(absolute_path + file_size + mtime_us)`。
    - 从 `SharedPreferences` 读 `idem:photo:{local_key}`：命中则复用 UUID；未命中则生成 UUIDv4 并写入。
    - 上传时把 UUID 放在 `Idempotency-Key` header。
    - 服务端 2xx 响应后删除该 `SharedPreferences` 条目；用户在 `RecordScreen` 主动移除待上传项时同步清理；APP 杀进程后重启仍能按 `local_key` 复用 UUID → 服务端命中缓存去重。
  - **后端**：
    - 新建 [`backend/app/middleware/idempotency.py`](backend/app/middleware/idempotency.py)，作用范围限定为 `POST /pets/{pet_id}/photos`（通过路由 `dependencies=[Depends(idempotency_guard)]` 注入，而不是全局中间件，避免影响无关端点）。
    - 首次请求：放行路由；在响应返回前把 `(status_code, response_body_bytes)` 用 `orjson` 打包后 `SETEX idem:photo:{user_id}:{key} 300 <payload>`。
    - 重复请求（同 user + 同 key）：命中即直接回放缓存的 status + body，不再进入上传处理逻辑。
    - 非法 key 处理：`Idempotency-Key` 必须为 UUIDv4 格式，否则 400 `INVALID_IDEMPOTENCY_KEY`；缺省（老客户端）路由按原逻辑放行但不做去重（向前兼容）。
- **验收**：
  - `tests/api/test_photos.py` 新增：
    - 同 user + 同 key + 同 body 连续重发，DB 中 photos 只增 N 条（N 为首次成功条数），第二次响应 body 与第一次字节一致。
    - 同 user + 同 key 但第一次部分失败，第二次重发返回第一次的完整（含 failures）body。
    - 不同 user 用同一 key 互不影响。
    - **APP 重启模拟**：同一个 TestClient 销毁重建（等效新 Dio 连接），保留 Redis 与 SharedPreferences 等价存储，重发同 key 仍命中缓存、photos 不重复插入。

#### 11) Health 模块分页重复代码抽象
- **现状**：[`backend/app/services/health.py`](backend/app/services/health.py) 共 659 行；Weight/Deworming/Vaccination/Routine 的 `list_*` 函数结构几乎一致（count + offset + order_by + paginate）。
- **目标**：抽出 `backend/app/services/_pagination.py`：
  ```python
  async def paginate_by_pet(
      db, model, *, pet_id: int, page: int, page_size: int,
      order_by: list,
  ) -> tuple[list[Any], int, int]: ...
  ```
  替换四处重复实现。
- **验收**：`health.py` 总行数降至 400 以内；四个 list 测试全部保持通过。

#### 12) 前端网络层 & 原图缓存
- **现状**：[`frontend/lib/services/api_client.dart`](frontend/lib/services/api_client.dart) 并发 401 可能触发多次 `/auth/refresh`；退出登录后 `OriginalPhotoCache` 仍保留前一账号的原图在磁盘上（隐私问题）。
- **目标**：
  - 增加 `Completer<String> _refreshLock`；并发 401 共享一个刷新 future。
  - `OriginalPhotoCache` 增 `clearAllForLogout()`：清掉所有 `photo_*` 和 `pending_*` 文件 + index.json，同时清掉内存 `_index`。
  - `AuthNotifier.logout()` / `ApiClient.onForceLogout` 在完成后 await 该方法。
- **验收**：
  - `test/services/api_client_single_flight_test.dart`：3 个并发 401 → 断言 `/auth/refresh` 只被调用 1 次。
  - `test/services/original_photo_cache_test.dart` 追加 `clearAllForLogout` 清盘用例。

---

### §1.2 核心模块文件级 checklist

为四个高价值文件给出 P0/P1/P2 条目，便于每条单独立项。

#### `[backend/app/services/storage.py](backend/app/services/storage.py)` — 247 LOC
| 优先级 | 动作 | 验收 |
|---|---|---|
| P0 | `_generate_thumbnail` 用 `with Image.open(io.BytesIO(file_data)) as img:` 语法关闭 Pillow 句柄；设置 `Image.MAX_IMAGE_PIXELS = 50_000_000` 防 zip-bomb/decompression-bomb。 | 单测：读取 100 张图后 `gc.collect()` 内存增量 < 5 MB |
| P0 | 为 `delete_photo_objects` / `delete_object_by_url` / `delete_objects_by_prefix` / `upload_pet_avatar` 增加 `async` 包装（内部 `asyncio.to_thread`）；调用方全部切到 async 版本。 | 压测：10 并发 DELETE 请求平均延迟 < 200 ms（当前同步实现会线性叠加） |
| P1 | `_ensure_bucket` 的进程内集合 `_initialized_buckets` 改为 FastAPI `lifespan` 启动时一次性初始化所有 bucket（photos/thumbnails/avatars）。 | `grep` 运行时调用点为 0；启动日志里看到三行 bucket ensure |
| P1 | `delete_object_by_url` 的 url 解析逻辑（`path.startswith('/media/')`）改为显式 `MEDIA_PREFIX` 常量，并对异常 URL 记录 warning 而不是静默 return。 | 单测覆盖 3 种非法 URL |
| P2 | `get_photo_presigned_url(expires_seconds=3600)` 增加边界：15 min ≤ expires ≤ 24 h，超出 clamp 到边界。 | 单测 |
| P2 | `EXT_MAP` 加上 `image/heic` / `image/heif` 兼容（目前前端已转 JPEG，后端作为兜底）。 | — |

#### `[backend/app/services/timeline.py](backend/app/services/timeline.py)` — 573 LOC
| 优先级 | 动作 | 验收 |
|---|---|---|
| P0 | `get_timeline_window` 当前顺序发送 ≥ 5 条查询（`_resolve_accessible_pet_ids`、`_date_range`、`_total_count`、主 fetch、`_has_more_newer`、`_has_more_older`）。改为：权限查询之后，用 `asyncio.gather` 并发 `_date_range` + `_total_count`；`_has_more_*` 合并成 1 条查询（同一 CTE / UNION）。 | Postgres 集成测试统计 `pg_stat_statements`，单次 timeline 请求 DB roundtrip ≤ 3 |
| P0 | 添加复合索引依赖说明（见 §1.1 第 2 条）；在文件顶部给出 `EXPLAIN` 期望走的索引名称注释。 | `tests/integration/test_indexes.py` 断言 |
| P1 | `_photo_to_item` 兜底 `(f"宠物#{photo.pet_id}", "cat")` 硬编码 `cat` 不准确。改为 `("未知宠物", "unknown")`，`TimelinePhotoItem.pet_type` 允许 `"unknown"`（前端已做枚举兼容）。 | 单测：孤儿 photo（pet 被删后残留）返回 `pet_type='unknown'` |
| P1 | `_validate_anchor_month_format` 抛出时 `from exc` 会把原始堆栈带给客户端 debug 页；在 prod 关闭 exception details。 | — |
| P2 | `MAX_LIMIT=100` 与前端页大小 40 对齐；当 `limit > 50` 打 warning 日志帮助发现异常客户端。 | — |

#### `[backend/app/services/health.py](backend/app/services/health.py)` — 659 LOC
| 优先级 | 动作 | 验收 |
|---|---|---|
| P0 | 抽 `_pagination.paginate_by_pet(...)`（见 §1.1 第 11 条），替换 `list_weights` / `list_dewormings` / `list_vaccinations` / `list_routines` 四个函数。 | 文件行数 < 400；四个 list 测试保持通过 |
| P0 | 四种 create 函数里的 `created_at=datetime.utcnow()` 全替换成 `utils.time.utcnow()`。 | `grep utcnow` 在本文件为 0 |
| P1 | `_calc_status`（驱虫）与 `_calc_routine_status`（日常）逻辑一致，只是字段名差异。抽 `_calc_cycle_status(reminder_enabled, cycle_days, last_date) -> dict`，两个上层函数适配 `last_dewormed_at` vs `last_performed_at` 的命名差异即可。 | 合并后代码行数 -80 |
| P1 | `get_deworming_status` / `get_routine_status` 每次发 3 条 `SELECT` 拉「最近一次记录」。改为一次 `SELECT ... WHERE type IN (...) GROUP BY type` 聚合，或用 `asyncio.gather`。 | Postgres 集成下 DB roundtrip 从 4 降到 2 |
| P2 | `VACCINE_PRESETS` 放到 `backend/app/constants/vaccines.py`，避免 service 文件承担配置职责。 | — |

#### `[frontend/lib/services/api_client.dart](frontend/lib/services/api_client.dart)` — 154 LOC
| 优先级 | 动作 | 验收 |
|---|---|---|
| P0 | 增加 `Completer<String>? _refreshInflight`：并发 401 命中同一个 Completer，避免多次 refresh。refresh 成功后原子替换 access token 并逐个 replay 原请求。 | `test/services/api_client_single_flight_test.dart` 新增，3 个并发 401 只触发 1 次 refresh |
| P0 | `onForceLogout` 新语义：先 await `OriginalPhotoCache.instance.clearAllForLogout()`，再清 `SharedPreferences` 的 token，最后触发 UI 跳转。 | `test/providers/auth_provider_test.dart` 用 fake 断言调用顺序 |
| P1 | `_RetryInterceptor` 的 `Duration(milliseconds: 500 * pow(2, retryCount))` 当 retryCount 取 2 时 = 2 s，整体 3 次 ≈ 3.5 s，可接受；但对未来扩展应 clamp max 4 s。 | — |
| P1 | 5xx 也做一次重试（当前只重试 timeout/connection）；5xx 重试需幂等，仅限 GET。 | 单测 mock 连续两次 500 → 第二次重试成功 |
| P2 | `LogInterceptor(requestBody: true, responseBody: true)` 在 `kDebugMode` 下仍会打印验证码 / access_token。对 `path.contains('/auth/')` 路径屏蔽 body。 | 单测断言打印内容不含 `code`、`access_token` |

---

## §2 自动化测试重构

### §2.1 现状评估

#### 后端（`backend/tests/`）
现有：
- [`tests/test_auth.py`](backend/tests/test_auth.py)：11 条（send-code 成功 / 非法手机号 / 限流 / 登录成功 / 错码 / 首次注册 / refresh / blacklist / logout / `/me` / `PUT /me`）。
- [`tests/test_health.py`](backend/tests/test_health.py)：Weight CRUD + 校验；Deworming CRUD + cycle + status + 无记录 + 校验；Vaccination CRUD + presets；跨用户 forbidden。
- [`tests/test_timeline.py`](backend/tests/test_timeline.py)：空、首页分页、pet_ids 权限、锚月直达/回退旧/回退新、非法参数、dates 分布、稳定序。

覆盖缺口：
- **Pets**：无任何端到端测试（只作为 helper 使用过 `POST /pets`）。缺 `GET /pets`、`GET /pets/{id}`、`PUT /pets/{id}`、`POST /pets/{id}/avatar`、`DELETE /pets/{id}` 的级联清理、`invite_code` 唯一性、owner/editor/viewer 权限。
- **Photos**：完全没有（上传、场景识别关闭 / 开启、多文件部分失败、超大 / 超数量、删除 MinIO 清理、`GET /photos/{id}/url`）。
- **Routines**：完全没有（CRUD + cycle + status）。
- **Auth 深水区**：refresh 过期、登出后 access 仍可用直到 TTL、用户 A 的 refresh 用 B 的 access 调 logout。
- **Dependencies**：`get_current_user` 面对伪造 token / 错误 type / user 被删的行为。
- **Storage 工具函数**：`delete_object_by_url` / `delete_objects_by_prefix` 的 URL 解析路径。

#### 前端（`frontend/test/`）
现有：
- `widget_test.dart`：最小导航冒烟。
- `providers/timeline_provider_test.dart`：`TimelineMerge` 算法、过滤器相等性、视图模式开关。
- `services/original_photo_cache_test.dart`：绑定 / 释放 / LRU / 冷启动持久化。

覆盖缺口：
- `auth_provider`（登录成功 / 失败、`_checkAuthStatus` 三分支、`onForceLogout`）。
- `api_client` 单飞 refresh 测试（见 §1 P0）。
- `health_reminder_scheduler`（`_runOnce` 重入合并、单 pet 失败不影响其它、trigger 天数计算边界）。
- `pet_provider`（selectedPetId 持久化、列表刷新时 fallback）。
- `timeline_provider` 的 `removePhotos`、`jumpToMonth` 本地命中 / 远端拉取两条路径。

---

### §2.2 分块重设计（后端）

目录结构：

```
backend/tests/
  _sqlite_compat.py           # 原 conftest 里的 monkey-patch 抽出
  conftest.py                 # 共享 fixtures: client, db, auth headers
  unit/
    test_security.py
    test_timeline_cursor.py
    test_pagination_helper.py
    test_config_guard.py
    test_logging.py
  api/
    test_auth.py              # 原文件迁过来 + 补 3 条
    test_pets.py              # 新
    test_photos.py            # 新
    test_health_weight.py     # 从 test_health.py 拆
    test_health_deworming.py
    test_health_vaccination.py
    test_health_routine.py    # 新
    test_timeline.py          # 原文件迁过来
    test_rate_limit.py        # 新
  integration/
    conftest.py               # Postgres container / alembic
    test_indexes.py
    test_timeline_extract.py
    test_numeric_precision.py
    test_enum_values.py
    test_migration_roundtrip.py
```

#### 新增测试用例清单

**`unit/test_security.py`**
- access/refresh token 往返（解码后 sub/type/jti 正确）。
- 过期 token 返回 `None`。
- 篡改 payload 后返回 `None`。
- 错误 algorithm 返回 `None`。

**`unit/test_timeline_cursor.py`**
- 编码 → 解码往返（多组随机日期）。
- `_decode_cursor` 对非 base64 / 缺字段 / 不合法日期抛 `AppException(400, INVALID_CURSOR)`。

**`unit/test_pagination_helper.py`**（§1.1 第 11 条配套）
- 4 种模型统一接口回归。

**`unit/test_config_guard.py`**（§1.1 第 6 条配套）
- `DEBUG=True` + 默认 key → 不抛。
- `DEBUG=False` + 默认 `JWT_SECRET_KEY` → 启动即 RuntimeError。
- `DEBUG=False` + 默认 `PUBLIC_BASE_URL` → RuntimeError。

**`api/test_auth.py`**（在原文件基础上补）
- refresh 过期 → 401 `INVALID_REFRESH_TOKEN`（用小 TTL 创建）。
- A 的 access + B 的 refresh 调 `/auth/logout` → 400 `REFRESH_TOKEN_MISMATCH`。
- logout 后立刻用 access 访问 `/auth/me` 仍能通过（access 无黑名单，与文档对齐）。

**`api/test_pets.py`**（新）
- create → list（内含自身）→ get（invite_code 仅 owner 可见）→ update 名称 → delete。
- Avatar 上传：合法格式、非法 content-type（400）、超 5 MB（400）、成功后 `avatar_url` 以 `PUBLIC_BASE_URL/media/avatars/...` 开头。
- Delete 级联：先创建 pet + 上传 1 张 photo + 1 条 weight，delete 后 SQL 层验证所有关联表记录为 0；MinIO 的 `delete_objects_by_prefix` 被调用（mock 断言）。
- Member 场景：为 pet 手工插入一条 `PetMember(role=MEMBER)` 绑定到 B，验证 B 能读但不能 update / delete / upload_avatar。

**`api/test_photos.py`**（新）
- 上传 1 / 3 / 5 张成功（mock `recognize_pet` + mock `upload_photo` 返回固定 key）。
- 6 张 → 400 `TOO_MANY_FILES`。
- 16 MB → 400 `FILE_TOO_LARGE`；混合合法 + 超大 → 部分成功，返回体 `success_count` 正确。
- 非法 content-type → 400 `UNSUPPORTED_IMAGE_TYPE`。
- 打开 `ENABLE_SERVER_PET_RECOGNITION=True`：mock `recognize_pet` 返回 `is_pet=False` → 失败且 `code=PET_NOT_DETECTED`。
- 上传时 `taken_at` 与 `files` 数量不一致 → 400 `TAKEN_AT_MISMATCH`。
- `Idempotency-Key` 复用：同 key 重复提交只写一条 photos 记录（§1.1 第 10 条生效后）。
- `DELETE /photos/{id}`：mock `delete_photo_objects` 被调用。
- `GET /photos/{id}/url` 返回签名 URL 且指向 `PUBLIC_BASE_URL`。

**`api/test_health_weight.py` / `test_health_deworming.py` / `test_health_vaccination.py` / `test_health_routine.py`**
- 拆自 `test_health.py`：每文件只处理单一模型的 CRUD / 校验 / 权限。
- `test_health_routine.py` 新增：
  - Routine CRUD（bath / nail_trim / grooming）。
  - Cycle PUT + status（`bath_cycle_days=30`、最近 29 天内有记录 → days_remaining=1，无记录 → next_due_at=None）。
  - `reminder_enabled=False` 时 status 里所有字段为 None。

**`api/test_timeline.py`**：保留原文件，迁到 `api/` 目录。

**`api/test_rate_limit.py`**（§1.1 第 9 条配套）
- 同 IP 对 `/auth/login` 11 次 → 第 11 次 429。
- 不同手机号 + 同 IP 被限流。

---

### §2.3 分块重设计（前端）

目录：
```
frontend/test/
  providers/
    auth_provider_test.dart            # 新
    timeline_provider_test.dart        # 扩展
  services/
    api_client_single_flight_test.dart # 新
    health_reminder_scheduler_test.dart# 新
    original_photo_cache_test.dart     # 扩展
  widget_test.dart                     # 保留
```

#### 新文件要点

**`providers/auth_provider_test.dart`**
- 使用 fake `AuthService` 替代真实实现。
- `_checkAuthStatus`：
  - 没有 token → `unauthenticated`。
  - 有 token + `getMe` 成功 → `authenticated`。
  - 有 token + `getMe` 401 但 refresh 成功 → `authenticated`。
  - 有 token + 两者都失败 → `unauthenticated` 且 `SharedPreferences` 已清。
- `login` 成功 / 失败路径设置 `state.error`。
- `logout` 调用 `OriginalPhotoCache.clearAllForLogout`（通过注入的 fake 验证调用）。

**`services/api_client_single_flight_test.dart`**
- 用 `DioAdapter`（`http_mock_adapter`）mock 出 3 个并发 401 请求和 1 个 refresh endpoint。
- 断言 refresh endpoint hit count = 1，3 个原请求都用新 token 重放成功。

**`services/health_reminder_scheduler_test.dart`**
- 注入 fake `PetService` / `HealthService` / `NotificationService`。
- 场景 A：`refresh()` 被连续调用 3 次，内部 `_runOnce` 只会被执行 2 次（第一次 + 合并后 1 次），不是 3 次。
- 场景 B：第一个 pet 的 `getDewormingStatus` 抛异常 → 第二个 pet 仍被调度。
- 场景 C：`daysRemaining=5` → `triggerDaysFromToday=2`；`daysRemaining=-3` → `triggerDaysFromToday=0`；`scheduledAt` 等于今天 09:00 已过则顺延到明天。

**`providers/timeline_provider_test.dart`**（扩展）
- `removePhotos`：删 3 张分布在 2 个月的照片，断言 `orderedPhotoIds`、`monthFirstPhotoIndex`、`monthDistribution`、`total` 全部正确。
- `jumpToMonth` 本地已有 → 同步返回 month 不调接口。
- `jumpToMonth` 本地无 → 调 service 拿锚月窗口，并把新 group 插到正确位置。

**`services/original_photo_cache_test.dart`**（扩展）
- `clearAllForLogout` 清掉 `photo_*` + `pending_*` 文件和 index。

---

### §2.4 Postgres 集成测试层

#### 基础设施
- 新增 `backend/requirements-test.txt`（独立于 `requirements.txt`）：
  - `testcontainers==4.*`
  - `psycopg[binary]>=3.2`
  - 其余原有测试依赖（`pytest`、`pytest-asyncio`、`aiosqlite` 等）从 `requirements.txt` 迁入。
- `tests/integration/conftest.py`：
  - session scope 启动 Postgres 16 容器（`PostgresContainer("postgres:16-alpine")`）。
  - 容器就绪后运行 `alembic upgrade head` 建表。
  - 每个测试用 savepoint 回滚，避免容器重启。
- `pytest.ini`：`markers = integration: requires postgres container`。

#### CI 策略（Q1 决定：脚手架备妥，当前不启用）
- **当前阶段不自动跑**：项目处于个人测试阶段，CI 工作流文件先准备好但不自动触发，避免白白消耗 runner 时间。
- 交付 `.github/workflows/postgres-integration.yml`（或等价路径）：
  - 仅配置 `on: workflow_dispatch`（手动触发），不配 `on: push` / `on: pull_request`。
  - Job 内跑 `pytest -m integration`，用 `services: postgres:16-alpine` 或 testcontainers 任选（推荐 testcontainers，与本地脚本一致）。
  - 文件顶部加注释：「正式发布前改为 `on: [push, pull_request]` 自动触发；当前仅手动触发，保留随时切换的能力」。
- **CI runner 要求（上线前启用时需满足）**：
  - GitHub Actions `ubuntu-latest` 原生支持 Docker；自托管 runner 预装 Docker Engine。
  - 公司网络受限时配置镜像源（例如 `registry.cn-hangzhou.aliyuncs.com/library/postgres:16-alpine`），通过 job env `TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX=registry.cn-hangzhou.aliyuncs.com/library/` 注入 testcontainers。

#### 默认执行策略
- **本地**：默认 `pytest` 只跑 SQLite + API 层；开发者按需 `pytest -m integration` 手动触发 Postgres 层。
- **CI**：当前不自动跑任何用例（沿用现状）。Postgres 集成层脚手架就绪、`workflow_dispatch` 可随时手动执行；Phase 1 上线前再把触发条件改为 `push` / `pull_request` 启用自动化。

#### 初版 4 条用例

**`test_indexes.py`**
- 对 `photos` 插 1000 条（10 个 pet 每 100 条），执行 `EXPLAIN` 主 timeline 查询，断言 `Index Scan`。
- 同理对 `weights`、`dewormings`、`vaccinations`、`routines`。

**`test_timeline_extract.py`**
- 往 photos 插入同一 pet_id 跨 2023-12 / 2024-01 / 2024-02 / 2024-03 的照片。
- 调 `GET /photos/timeline/dates`，断言月份顺序与 SQLite 一致。
- 跨时区边界（UTC vs 本地时间）用例：photo 用 UTC 凌晨 0 点 10 分入库，本地时间是前一天。确认服务端在 PG 下按 `taken_at`（date 类型）分组不受影响。

**`test_numeric_precision.py`**
- 插入 Weight `4.355` → `Numeric(5,2)` 四舍五入为 `4.36`（PG）或 `4.35`（SQLite 行为差异警告写入测试注释）。
- 插入 `999.99` 边界成功；`1000.00` 失败。

**`test_enum_values.py`**
- 插入全部 PetType / DewormingType / RoutineType 枚举值，读回等值。
- 尝试插入非法值 → 抛 `DataError`。

**`test_migration_roundtrip.py`**
- `alembic upgrade head` → `alembic downgrade base` → `alembic upgrade head` 依然成功。

---

### §2.5 告警清单与修复

在本阶段开头跑一次 `cd backend && pytest -q 2>&1 | tee /tmp/pytest-baseline.log` 作为基线，然后逐条消除：

| 告警源 | 现状 | 修法 |
|---|---|---|
| `SQLiteTypeCompiler.visit_big_integer` monkey-patch | 放在 `tests/conftest.py` 顶部，对所有测试生效（即便未来用 PG） | 抽到 `tests/_sqlite_compat.py`，仅在 SQLite fixture 中调用 |
| `PytestUnraisableExceptionWarning: coroutine was never awaited` | 偶发（取决于测试顺序）；root cause 为 `patch.object(redis_mod, ...)` 的生命周期与 `async_sessionmaker` 回收冲突 | `pytest.ini` 加 `asyncio_mode = auto`；`conftest.py` 的 patch 改为 `async with AsyncExitStack` 模式 |
| `DeprecationWarning: datetime.datetime.utcnow()` | 多处 | §1.1 第 3 条源码替换；CI 用 `-W error::DeprecationWarning` 卡门 |
| `pydantic PydanticDeprecatedSince20` | pydantic 2.9 下若有旧语法 | `grep` 确认无 `.dict()` / `.parse_obj()` 残留 |
| `RuntimeWarning: coroutine 'xxx' was never awaited` | 来自 patched async mocks | 将 `patch.object(..., new_callable=AsyncMock)` 统一，避免混用 side_effect |
| `pytest-asyncio` session scope fixture 警告 | 若存在 | 固定 `loop_scope="session"` |

修法执行顺序建议：先加 `pytest.ini` 配置（治表），再配合 §1.1 第 3 条源码替换（治本）。

---

## §3 执行任务清单（按优先级 + 按 agent 工作量分块）

本节把 §1、§2 里散落的所有子任务扁平成一条线性清单，按 P0 → P1 → P2 排序；每个 chunk 设计成 **一次 agent turn 能完成**的工作量（约 1 个主文件 + 相关测试，或一套脚手架），便于逐 chunk 立项、逐 chunk 提交。

### 每个 chunk 的通用验收
1. 涉及源码的 chunk：先有对应自动化测试、测试先绿，再合并。
2. 合并后不破坏 `cd backend && pytest -q` 与 `cd frontend && flutter test` 全绿。
3. chunk 描述中必须引用本文档对应章节号（例如「§1.1 第 4 条」「§2.2 api/test_photos.py」）。
4. 任何影响 public API 行为的 chunk，同步补一行到 step1–7 的相关 doc。

---

### Phase P0 — 安全网 + 稳定性基线

#### A. 测试脚手架与补齐（先于所有后端重构）

- **Chunk A-1｜测试脚手架与配置**（§2.5）
  - 新增 `backend/tests/_sqlite_compat.py` 抽出 `SQLiteTypeCompiler` monkey-patch，仅在 SQLite fixture 中调用。
  - 新增 `backend/pytest.ini`：`asyncio_mode = auto`、`markers = integration: requires postgres container`、`filterwarnings = error::DeprecationWarning`（本 chunk 暂允许失败，等 Chunk B-1 完成后再开启严格模式）。
  - 把现有 `tests/test_auth.py` / `tests/test_health.py` / `tests/test_timeline.py` 移到 `tests/api/`（暂不拆分内容）。
  - 记录一次基线 `pytest -q` 输出到 PR 描述。

- **Chunk A-2｜拆分 test_health.py + 新增 routine**（§2.2）
  - `tests/api/test_health.py` 拆成 `test_health_weight.py` / `test_health_deworming.py` / `test_health_vaccination.py`；内容直接搬运现有用例。
  - 新增 `tests/api/test_health_routine.py`：Routine CRUD + cycle + status（启用 / 禁用两组）+ 权限。

- **Chunk A-3｜补 test_auth.py 三条 + 单元测试**（§2.2）
  - `tests/api/test_auth.py` 补：refresh 过期 → 401；A access + B refresh → 400 `REFRESH_TOKEN_MISMATCH`；logout 后 access 仍可用直到 TTL。
  - 新增 `tests/unit/test_security.py`：access/refresh 往返、过期、类型区分、篡改拒绝。
  - 新增 `tests/unit/test_timeline_cursor.py`：`_encode_cursor` / `_decode_cursor` 往返与非法输入。

- **Chunk A-4｜api/test_pets.py**（§2.2，新文件）
  - CRUD / invite_code 唯一性 / owner-vs-editor-vs-viewer / avatar 上传成功 / 非法 content-type / 超 5 MB / delete 级联清理（断言关联表已空 + MinIO `delete_objects_by_prefix` 被调用）。

- **Chunk A-5｜api/test_photos.py**（§2.2，新文件）
  - 单/多文件上传、超 5 张、超 15 MB、非法类型、部分失败；`ENABLE_SERVER_PET_RECOGNITION=True` 下的 `PET_NOT_DETECTED`；delete 触发 MinIO；`GET /photos/{id}/url` 签名 URL 指向 `PUBLIC_BASE_URL`。
  - Idempotency 相关用例留到 P1 Chunk D-5 一起写。

#### B. 后端核心重构

- **Chunk B-1｜datetime.utcnow 全局替换**（§1.1 第 3 条）
  - 新增 `backend/app/utils/time.py` 提供 `utcnow()`。
  - 替换 `utils/security.py` / `services/auth.py` / `services/pet.py` / `services/health.py` / `api/v1/photos.py` / 所有 model `default=` 里的 `datetime.utcnow`。
  - 完成后把 Chunk A-1 的 `filterwarnings = error::DeprecationWarning` 打开并验证 `pytest -q` 全绿。

- **Chunk B-2｜复合索引 Alembic 迁移**（§1.1 第 2 条）
  - 新增一个 revision，给 `photos / weights / dewormings / vaccinations / routines / pet_members` 加 §1.1 第 2 条列出的复合索引。
  - SQLite 层无法验证走索引，仅断言迁移 up/down 成功；走索引的断言交给 P1 Chunk E-2 的 Postgres 集成层。

- **Chunk B-3｜数据库连接池 + get_db 语义**（§1.1 第 1 条）
  - `[backend/app/database.py](backend/app/database.py)` 引入 `pool_size / max_overflow / pool_pre_ping / pool_recycle`；新增 `DB_ECHO` 配置项。
  - 去掉 `get_db` 里的隐式 commit；Services 层写操作显式 `await db.commit()`（保留 `flush` 的地方不变，commit 由路由或 service 出口统一调用）。
  - 新增 `tests/unit/test_db_session.py`：一个 GET 路由不触发 `COMMIT`（sqlalchemy event 监听）。

- **Chunk B-4｜启动安全自检**（§1.1 第 6 条）
  - 新增 `backend/app/utils/production_check.py::assert_production_safe(settings)`；在 `main.py` 的 `lifespan` 里调用。
  - `DEBUG=True` 立即 `return`；`DEBUG=False` 对默认 `JWT_SECRET_KEY` / `MINIO_SECRET_KEY` / `ALIYUN_*` / `PUBLIC_BASE_URL` 抛 `RuntimeError`，对 `JWT_SECRET_KEY` 弱强度打 warning。
  - 新增 `tests/unit/test_config_guard.py`。

- **Chunk B-5｜storage 层 async 化 + Pillow 安全**（§1.1 第 4 条 + §1.2 storage P0）
  - 在 `[backend/app/services/storage.py](backend/app/services/storage.py)` 新增 `aupload_photo / aupload_pet_avatar / adelete_photo_objects / adelete_object_by_url / adelete_objects_by_prefix`（内部 `asyncio.to_thread`）。
  - 调用方（`api/v1/photos.py` delete 分支、`services/pet.py` delete/upload_avatar）切到 async 版本。
  - `_generate_thumbnail` 用 `with Image.open(...) as img:`；设置 `Image.MAX_IMAGE_PIXELS = 50_000_000`。
  - `_ensure_bucket` 改为 `lifespan` 启动时一次性初始化三个 bucket（photos / thumbnails / avatars）。
  - 更新对应测试 mock。

- **Chunk B-6｜get_current_user_id 拆分**（§1.1 第 5 条）
  - `[backend/app/dependencies.py](backend/app/dependencies.py)` 新增 `get_current_user_id() -> int`（仅解码 JWT）。
  - `api/v1/pets.py / photos.py / health.py` 的默认鉴权迁到 `get_current_user_id`；Service 签名 `current_user: User` → `user_id: int`。
  - `api/v1/auth.py` 中 `PUT /auth/me` 继续用 `get_current_user`。
  - 新增单测：GET /pets 请求不触发 `SELECT users`。

#### C. 前端核心

- **Chunk C-1｜ApiClient 单飞刷新 + 退登清盘**（§1.1 第 12 条 + §1.2 api_client P0）
  - `[frontend/lib/services/api_client.dart](frontend/lib/services/api_client.dart)` 加 `Completer<String>? _refreshInflight`。
  - `[frontend/lib/services/original_photo_cache.dart](frontend/lib/services/original_photo_cache.dart)` 新增 `clearAllForLogout()`；在 `AuthNotifier.logout` / `onForceLogout` 里 await 调用。

- **Chunk C-2｜前端 P0 测试**（§2.3）
  - 新增 `test/services/api_client_single_flight_test.dart`（3 并发 401 只触发 1 次 refresh）。
  - 新增 `test/providers/auth_provider_test.dart`（登录成功 / 失败 / `_checkAuthStatus` 三分支 / `onForceLogout` 顺序）。
  - 扩展 `test/services/original_photo_cache_test.dart`：`clearAllForLogout` 清盘用例。

---

### Phase P1 — 架构与可读性

#### D. 后端架构升级

- **Chunk D-1｜JWT `jti` 切换**（§1.1 第 7 条）
  - `utils/security.py`：`create_refresh_token` 加 `jti`；`decode_token` 对 refresh 强制 `jti` 校验。
  - `services/redis.py`：黑名单 key 改为 `auth:refresh:jti:{jti}`。
  - `services/auth.py`：`refresh_access_token` / `logout` 读 `jti`。
  - 新增一次性脚本 `backend/scripts/flush_legacy_refresh_blacklist.py`（dry-run + 实际 run 两种模式，基于 `SCAN MATCH`）。
  - `tests/api/test_auth.py` 补 §1.1 第 7 条验收里的三条用例。
  - 本地 Redis 直接 `FLUSHDB` 即可。

- **Chunk D-2｜结构化日志 + 请求 ID**（§1.1 第 8 条）
  - 新增 `backend/app/utils/logging.py` JSON formatter + `RequestIdMiddleware` + `AccessLogMiddleware`。
  - `services/storage.py` 的 `except: pass` 全部改为 `except Exception as e: logger.warning(...)`。
  - 新增 `tests/unit/test_logging.py`：request id 在 `contextvars` 可读。

- **Chunk D-3｜health 分页抽象 + cycle status 合并**（§1.1 第 11 条 + §1.2 health P1）
  - 新增 `backend/app/services/_pagination.py::paginate_by_pet`，替换 `list_weights / list_dewormings / list_vaccinations / list_routines`。
  - 抽 `_calc_cycle_status(reminder_enabled, cycle_days, last_date)`，合并驱虫与日常 status 计算。
  - `health.py` 行数降至 < 400；新增 `tests/unit/test_pagination_helper.py`。

- **Chunk D-4｜timeline 查询合并 + 兜底**（§1.2 timeline P0/P1）
  - `get_timeline_window` 用 `asyncio.gather` 并发 `_date_range` + `_total_count`；`_has_more_newer` / `_has_more_older` 合并为 1 条 SQL。
  - `_photo_to_item` 兜底 `("未知宠物", "unknown")`；`TimelinePhotoItem.pet_type` 允许 `"unknown"`。
  - `_validate_anchor_month_format` 的 `from exc` 在 prod 隐藏原始堆栈（配合 Chunk B-4 的 `DEBUG=False` 判定）。

- **Chunk D-5｜Idempotency-Key 后端中间件**（§1.1 第 10 条）
  - 新增 `backend/app/middleware/idempotency.py`（局部 `Depends(idempotency_guard)` 注入到 `POST /pets/{pet_id}/photos`）。
  - Redis 键 `idem:photo:{user_id}:{key}`，body 用 `orjson`。
  - `tests/api/test_photos.py` 追加 §1.1 第 10 条验收的四组用例（含"TestClient 销毁重建模拟 APP 重启"）。

- **Chunk D-6｜Idempotency-Key 前端持久化**（§1.1 第 10 条）
  - `[frontend/lib/services/photo_service.dart](frontend/lib/services/photo_service.dart)` 实现 `local_key = sha1(path + size + mtime_us)` + SharedPreferences 持久化。
  - 成功响应后清理 SP 条目；用户移除待上传条目时同步清理。
  - 新增 `test/services/photo_service_idempotency_test.dart`。

#### E. Postgres 集成层（脚手架就绪，CI 暂不启用）

- **Chunk E-1｜Postgres 集成层脚手架**（§2.4）
  - 新增 `backend/requirements-test.txt`（testcontainers、psycopg[binary]、pytest-asyncio、aiosqlite 迁入）。
  - 新增 `backend/tests/integration/conftest.py`：session scope 拉起 `postgres:16-alpine`，`alembic upgrade head`，savepoint 回滚。
  - 新增 `.github/workflows/postgres-integration.yml`：`on: workflow_dispatch`，注释写明「发布前改为 `push/pull_request` 自动触发」。

- **Chunk E-2｜index + migration roundtrip 用例**（§2.4）
  - `tests/integration/test_indexes.py`：5 张表主查询 `EXPLAIN` 含 `Index Scan`。
  - `tests/integration/test_migration_roundtrip.py`：`upgrade head → downgrade base → upgrade head` 三轮全绿。

- **Chunk E-3｜SQL 行为差异用例**（§2.4）
  - `tests/integration/test_timeline_extract.py` / `test_numeric_precision.py` / `test_enum_values.py`（打包在一个 chunk 里，每个文件 100-150 LOC）。

#### F. 前端 P1 测试

- **Chunk F-1｜health_reminder_scheduler_test.dart**（§2.3）
  - 重入合并、单 pet 失败不影响其它、`triggerDaysFromToday` 与 9:00 顺延逻辑。

- **Chunk F-2｜timeline_provider_test.dart 扩展**（§2.3）
  - `removePhotos` 分组 / 计数正确；`jumpToMonth` 本地命中与远端拉取两条路径。

---

### Phase P2 — 收尾

- **Chunk G-1｜CORS + IP 级限流**（§1.1 第 9 条）
  - `main.py` 注册 `CORSMiddleware`（白名单从 `CORS_ORIGINS` 读）。
  - 接入 `slowapi` 或自实现 Redis 令牌桶，对 `/auth/send-code` / `/auth/login` / `/auth/refresh` 按 IP 限流。
  - 新增 `tests/api/test_rate_limit.py`。

- **Chunk G-2｜api_client.dart 重试改进 + 日志脱敏**（§1.2 api_client P1/P2）
  - `_RetryInterceptor` clamp max 4 s；对 5xx GET 重试一次。
  - `LogInterceptor` 对 `path.contains('/auth/')` 屏蔽 body。

- **Chunk G-3｜storage.py 收尾**（§1.2 storage P1/P2）
  - `delete_object_by_url` 引入 `MEDIA_PREFIX` 常量 + 异常 URL warning。
  - `get_photo_presigned_url` clamp 15 min ~ 24 h。
  - `EXT_MAP` 兼容 `image/heic` / `image/heif`。

- **Chunk G-4｜timeline.py 收尾**（§1.2 timeline P2）
  - `MAX_LIMIT` warning（limit > 50 时）。
  - `_validate_anchor_month_format` prod 隐藏堆栈已在 D-4 完成，此 chunk 仅做 `MAX_LIMIT` 对齐注释与前端 `40` 的一致性说明。

- **Chunk G-5｜health.py 收尾**（§1.2 health P2）
  - `VACCINE_PRESETS` 迁到 `backend/app/constants/vaccines.py`。

- **Chunk G-6｜Alembic 迁移合并（可选）**
  - 当前 3 条 step1/step5 迁移可合并为单一 baseline；非必须，拖到正式上线前再做。

---

### chunk 总览

| 阶段 | chunk 数 | 说明 |
|---|---|---|
| P0 – A（测试补齐） | 5 | Chunk A-1 ~ A-5 |
| P0 – B（后端核心） | 6 | Chunk B-1 ~ B-6 |
| P0 – C（前端核心） | 2 | Chunk C-1 ~ C-2 |
| P1 – D（后端架构） | 6 | Chunk D-1 ~ D-6 |
| P1 – E（Postgres 集成层） | 3 | Chunk E-1 ~ E-3 |
| P1 – F（前端测试） | 2 | Chunk F-1 ~ F-2 |
| P2 – G（收尾） | 6 | Chunk G-1 ~ G-6 |
| **合计** | **30** | |

建议执行顺序严格按 P0 → P1 → P2，且每段内按字母+编号顺序推进；P0 的 A 段（测试脚手架）必须先于 B 段，否则 B 段重构没有安全网。

---

## §4 已确认决策（2026-04-18 敲定）

本节记录 Phase 1 启动 Step 8 前，项目 owner 对 4 个关键分岔问题的最终选择。每项给出「选定方案 / 关键实施要点 / 细节所在章节」，便于后续 PR 反向追溯。

### 决策 1：Postgres 集成测试脚手架就绪，CI 暂不启用
- **选定方案**：本阶段准备好完整脚手架（`requirements-test.txt` + `tests/integration/conftest.py` + `pytest.ini` marker + `.github/workflows/postgres-integration.yml`），但 workflow 仅配置 `workflow_dispatch`，默认不自动触发；本地开发者按需 `pytest -m integration`。
- **关键实施要点**：
  - 当前处于个人测试阶段，避免 CI 无谓消耗；脚手架就位，上线前改 workflow 触发条件即可启用。
  - workflow 文件头注释写明「发布前改为 `on: [push, pull_request]` 启用自动化」，保留随时切换的能力。
  - 上线前启用时需保证 runner 具备 Docker 能力；公司网络受限时通过镜像源环境变量 `TESTCONTAINERS_HUB_IMAGE_NAME_PREFIX` 注入 testcontainers。
- **细节章节**：§2.4；落地拆分在 §3 Chunk E-1 ~ E-3。

### 决策 2：`Idempotency-Key` Phase 1 完整落地（含前端持久化）
- **选定方案**：前端 UUID + `SharedPreferences` 按 `local_key` 持久化；后端 Redis 缓存完整响应 5 分钟；仅作用于 `POST /pets/{pet_id}/photos`。
- **关键实施要点**：
  - 前端 `local_key = sha1(path + size + mtime_us)`，保证 APP 杀进程重启后仍能命中同一 UUID。
  - 后端用 `Depends(idempotency_guard)` 局部注入，不做全局中间件，避免影响无关端点。
  - 对缺省 `Idempotency-Key` 的请求向前兼容：按原路径放行但不去重，不回退为错误。
  - 测试需覆盖「APP 重启模拟 + 同 key 重发不重复」路径。
- **细节章节**：§1.1 第 10 条；落地拆分在 §3 Chunk D-5（后端）+ D-6（前端）。

### 决策 3：JWT `jti` 立即切换
- **选定方案**：不做灰度双读期；`decode_token` 对 refresh 类型强制要求 `jti` 字段存在；老格式 token 在新版后端上线瞬间失效。
- **关键实施要点**：
  - 项目当前处于个人测试阶段，不涉及外部用户，直接发新版后端即可；无需公告 / 分阶段 / 回流监控。
  - 客户端侧无需改动：现有 `api_client` 的 `/auth/refresh` 401 → `onForceLogout` 链路自动把测试账号引回登录页。
  - 可选：跑 `backend/scripts/flush_legacy_refresh_blacklist.py`（dry-run + 正式 run）清 `auth:refresh:blacklist:*`；本地 Redis 也可直接 `FLUSHDB`。
- **细节章节**：§1.1 第 7 条；落地拆分在 §3 Chunk D-1。

### 决策 4：启动自检在 `DEBUG=True` 下完全静默
- **选定方案**：`assert_production_safe` 在 `DEBUG=True` 时立即 `return`，不抛异常也不打任何日志/warning。
- **关键实施要点**：
  - 保证开发与 pytest 环境启动输出干净，不出现误导性警告。
  - `DEBUG=False` 下的默认值检查与 `JWT_SECRET_KEY` 强度 warning 完全保留。
  - 新人可能用默认值开发的风险由上线前的部署 checklist + `DEBUG=False` 默认值检查兜底。
- **细节章节**：§1.1 第 6 条；落地在 §3 Chunk B-4。
