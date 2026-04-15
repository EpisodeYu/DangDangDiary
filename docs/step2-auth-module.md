# Step 2: 认证模块

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL 技术栈。本步骤在 Step 1 已完成的项目骨架之上，落地 Phase 1 的认证基础能力，并为 Step 3 之后的所有受保护接口提供统一登录态。

本步骤完成后，客户端应具备以下能力：

1. 用手机号获取短信验证码。
2. 用手机号 + 验证码登录，首次登录自动注册用户。
3. 持久化 `access_token` 与 `refresh_token`。
4. 访问受保护接口时自动携带 token。
5. `access_token` 过期后自动刷新一次并重试原请求。
6. 支持获取当前用户信息、更新昵称、单设备退出登录。

---

## 0. 前置依赖与当前基础

### 0.1 前置依赖

- Step 1 已完成。
- PostgreSQL、Redis、Nginx 已可用。
- FastAPI 与 Flutter 骨架已建立。
- `users` 表与初始迁移已存在。
- 全局约定继续遵循 `docs/00-global-rules.md`。

### 0.2 实现前后仓库状态

> 以下为 Step 2 **实现前**的状态（仅供考古参考，当前仓库已全部完成）。

后端 Step 1 骨架状态：

- `backend/app/api/v1/auth.py` 已存在，但仍是占位路由。
- `backend/app/schemas/auth.py` 已存在，但只有最基础的请求/响应模型。
- `backend/app/config.py` 已包含 JWT、Redis、阿里云短信相关配置项。
- `backend/app/dependencies.py` 已预留给通用依赖注入，但认证依赖尚未实现。
- `backend/app/services/` 与 `backend/app/utils/` 目录不存在。

前端 Step 1 骨架状态：

- `frontend/lib/services/api_client.dart` 已有 Dio 与 token 注入逻辑，但 `401 -> refresh` 仍未实现。
- `frontend/lib/config/router.dart` 已有主导航结构（全局 `final router`），但还没有登录态守卫。
- `frontend/lib/screens/auth/login_screen.dart` 仍是占位页面。
- `frontend/lib/config/constants.dart` 已作为统一配置入口存在。
- `frontend/lib/providers/` 和 `frontend/lib/models/` 目录不存在。

> Step 2 完成后的仓库变化见下方 §6「实际变更文件清单」。

### 0.3 本步骤的实现边界

本步骤必须完成：

- `POST /api/v1/auth/send-code`
- `POST /api/v1/auth/login`
- `POST /api/v1/auth/refresh`
- `POST /api/v1/auth/logout`
- `GET /api/v1/auth/me`
- `PUT /api/v1/auth/me`
- Flutter 登录页
- token 持久化
- 冷启动恢复登录
- 401 后自动刷新一次 access token
- 后端重点自动化测试

本步骤不做：

- 微信登录
- 多设备会话管理界面
- 头像上传
- 并发 `401` 的单飞刷新优化

说明：

- `PUT /api/v1/auth/me` 在 Step 2 只要求支持更新 `nickname`。
- `avatar_url` 可以在用户信息中返回，但不要求在 Step 2 提供上传或编辑能力。
- 并发 `401` 时只允许“简单方案”：每个失败请求各自尝试刷新一次。更稳健的单飞刷新机制留到后续优化，不在本步骤验收范围内。

---

## 1. 认证流程

```text
用户输入手机号
  -> 请求发送验证码
  -> 后端校验手机号与频控
  -> 调用阿里云 Dypnsapi 发送验证码
  -> Redis 保存验证码与频控标记

用户输入验证码
  -> 请求登录
  -> 后端校验 Redis 中的验证码
  -> 首次登录自动创建 users 记录
  -> 生成 access_token + refresh_token
  -> Flutter 持久化 token 与用户信息
  -> 进入主流程页面

后续接口访问
  -> 自动携带 access_token
  -> 若返回 401，则尝试调用 /auth/refresh
  -> 刷新成功后重试原请求一次
  -> 刷新失败则清空本地登录态并回到 /login
```

---

## 2. 实施顺序建议

为了降低联调复杂度，本步骤建议严格按以下顺序推进：

1. 先补全后端认证链路与自动化测试。
2. 用 FastAPI Swagger `/docs` 验证接口行为与错误格式。
3. 再补全 Flutter 登录页、认证状态管理、路由守卫与自动刷新。
4. 最后做真机或模拟器联调。

不要一开始同时改后端和前端，否则很容易在短信、Redis、路由守卫三处同时卡住。

---

## 3. 后端 API 规格

### 3.1 通用约定

- 所有接口前缀都是 `/api/v1/auth`。
- 所有字段使用 `snake_case`。
- 业务错误统一返回：

```json
{
  "code": "ERROR_CODE",
  "message": "面向用户或调用方的错误描述",
  "details": null
}
```

- `RequestValidationError` 处理器在 Step 2 中被增强：会检查失败字段名，将 `phone` 字段错误映射为 `INVALID_PHONE`，`code` 字段映射为 `INVALID_VERIFY_CODE`，`nickname` 字段映射为 `INVALID_NICKNAME`，其余字段回退到 `VALIDATION_ERROR`。
- 需要认证的接口通过 `Authorization: Bearer {access_token}` 传递 access token。
- 中国大陆手机号校验规则：`^1[3-9]\\d{9}$`
- 验证码校验规则：6 位数字。

### 3.2 Token 约定

- `access_token` 有效期：2 小时。
- `refresh_token` 有效期：30 天。
- JWT 至少包含以下字段：
  - `sub`: 用户 ID，字符串形式。
  - `exp`: 过期时间。
  - `type`: `access` 或 `refresh`。
- `refresh_token` 黑名单写入 Redis，TTL 应与该 token 的剩余有效期一致。

### 3.3 Redis key 约定

- 验证码：`sms:verify:{phone}`
- 验证码频控：`sms:limit:{phone}`
- refresh token 黑名单：`auth:refresh:blacklist:{refresh_token}`

如果实现时决定对 refresh token 做哈希后再落 Redis，也可以，但必须保持以下语义不变：

- `logout` 仅拉黑当前提交的 refresh token。
- 被拉黑的 refresh token 后续不能再用于 `/auth/refresh`。
- 其他设备的 refresh token 不受影响。

### 3.4 短信服务约定

本步骤运行时默认接入真实阿里云 Dypnsapi，不再以内置 mock 或控制台打印验证码作为默认方案。

实现要求：

- 使用阿里云号码认证服务 `SendSmsVerifyCode`。
- 从环境变量读取：
  - `ALIYUN_ACCESS_KEY_ID`
  - `ALIYUN_ACCESS_KEY_SECRET`
  - `ALIYUN_SMS_SIGN_NAME`
  - `ALIYUN_SMS_TEMPLATE_CODE`
- 默认签名与模板继续沿用 Step 1 / 技术方案中的系统赠送值：
  - `速通互联验证码`
  - `100001`
- 请求参数应设置：
  - `CodeType=1`
  - `CodeLength=6`
  - `ValidTime=300`
  - `Interval=60`
  - `DuplicatePolicy=1`
  - `ReturnVerifyCode=true`
  - `TemplateParam={"code":"##code##","min":"5"}` — 必须同时传 `code` 和 `min` 两个变量，与模板占位符一一对应。

**阿里云赠送短信模板定义**（供后续步骤参考）：

| 模板名称 | 模板 CODE | 模板内容 |
|---------|-----------|---------|
| 登录/注册模板 | `100001` | 您的验证码为${code}。尊敬的客户，以上验证码${min}分钟内有效，请注意保密，切勿告知他人。 |
| 修改绑定手机号模板 | `100002` | 尊敬的客户，您正在进行修改手机号操作，您的验证码为${code}。以上验证码${min}分钟内有效，请注意保密，切勿告知他人。 |
| 重置密码模板 | `100003` | 尊敬的客户，您正在进行重置密码操作，您的验证码为${code}。以上验证码${min}分钟内有效，请注意保密，切勿告知他人。 |
| 绑定新手机号模板 | `100004` | 尊敬的客户，您正在进行绑定手机号操作，您的验证码为${code}。以上验证码${min}分钟内有效，请注意保密，切勿告知他人。 |
| 验证绑定手机号模板 | `100005` | 尊敬的客户，您正在验证绑定手机号操作，您的验证码为${code}。以上验证码${min}分钟内有效，请注意保密，切勿告知他人。 |

> 所有模板都包含 `${code}` 和 `${min}` 两个变量。调用 `SendSmsVerifyCode` 时 `TemplateParam` 必须提供这两个 key，否则会返回 `isv.INVALID_PARAMETERS`。

如果运行环境缺少阿里云必需配置，不要偷偷降级为本地 mock；应直接报错并提示环境未配置完成。

自动化测试中可以 mock 阿里云 SDK，但运行时联调必须接真实阿里云。

### 3.5 `POST /api/v1/auth/send-code`

请求体：

```json
{
  "phone": "13800138000"
}
```

成功响应 `200`：

```json
{
  "expire_seconds": 300
}
```

失败场景：

- `400 INVALID_PHONE`：手机号格式不合法。
- `429 SMS_RATE_LIMITED`：60 秒内重复请求。
- `502 SMS_SEND_FAILED`：调用阿里云失败，或阿里云返回非成功状态。

业务逻辑：

1. 校验手机号格式。
2. 检查 `sms:limit:{phone}` 是否存在。
3. 调用阿里云发送验证码。
4. 从阿里云响应中取回验证码明文。
5. 将验证码写入 `sms:verify:{phone}`，TTL 300 秒。
6. 将频控 key 写入 `sms:limit:{phone}`，TTL 60 秒。
7. 返回 `expire_seconds=300`。

### 3.6 `POST /api/v1/auth/login`

请求体：

```json
{
  "phone": "13800138000",
  "code": "123456"
}
```

成功响应 `200`：

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIs...",
  "refresh_token": "eyJhbGciOiJIUzI1NiIs...",
  "token_type": "bearer",
  "user": {
    "id": 1,
    "phone": "13800138000",
    "nickname": null,
    "avatar_url": null
  }
}
```

失败场景：

- `400 INVALID_PHONE`：手机号格式不合法。
- `400 INVALID_VERIFY_CODE`：验证码错误、缺失或已过期。

业务逻辑：

1. 校验手机号与验证码格式。
2. 从 Redis 读取 `sms:verify:{phone}`。
3. 对比验证码，不匹配则返回错误。
4. 验证成功后立即删除验证码 key，保证一次性使用。
5. 按手机号查询 `users` 表。
6. 若用户不存在，则自动创建用户记录。
7. 生成 access token 与 refresh token。
8. 返回 token 对与用户信息。

### 3.7 `POST /api/v1/auth/refresh`

请求体：

```json
{
  "refresh_token": "eyJhbGciOiJIUzI1NiIs..."
}
```

成功响应 `200`：

```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIs...",
  "token_type": "bearer"
}
```

失败场景：

- `401 INVALID_REFRESH_TOKEN`：refresh token 无效、过期、类型错误或已被拉黑。

业务逻辑：

1. 校验 refresh token。
2. 检查是否在 Redis 黑名单中。
3. 解析出用户 ID。
4. 确认用户仍存在。
5. 生成新的 access token。
6. 不轮换 refresh token，本步骤保持简单实现。

### 3.8 `POST /api/v1/auth/logout`

请求头：

```text
Authorization: Bearer {access_token}
```

请求体：

```json
{
  "refresh_token": "eyJhbGciOiJIUzI1NiIs..."
}
```

成功响应：

- `204 No Content`

失败场景：

- `401 INVALID_ACCESS_TOKEN`：access token 无效或过期。
- `401 INVALID_REFRESH_TOKEN`：refresh token 无效、过期或类型错误。
- `400 REFRESH_TOKEN_MISMATCH`：提交的 refresh token 不属于当前 access token 对应用户。

业务逻辑：

1. 先通过 access token 获取当前用户。
2. 校验请求体中的 refresh token。
3. 确认 refresh token 里的用户 ID 与当前用户一致。
4. 将该 refresh token 加入 Redis 黑名单，TTL 为剩余有效期。
5. 只作废这一个 refresh token，不影响其他设备。

### 3.9 `GET /api/v1/auth/me`

请求头：

```text
Authorization: Bearer {access_token}
```

成功响应 `200`：

```json
{
  "id": 1,
  "phone": "13800138000",
  "nickname": "当当妈妈",
  "avatar_url": null
}
```

失败场景：

- `401 INVALID_ACCESS_TOKEN`
- `401 USER_NOT_FOUND`

### 3.10 `PUT /api/v1/auth/me`

请求头：

```text
Authorization: Bearer {access_token}
```

请求体：

```json
{
  "nickname": "新昵称"
}
```

成功响应 `200`：

```json
{
  "id": 1,
  "phone": "13800138000",
  "nickname": "新昵称",
  "avatar_url": null
}
```

失败场景：

- `401 INVALID_ACCESS_TOKEN`
- `400 INVALID_NICKNAME`

约束说明：

- Step 2 只要求更新 `nickname`。
- `nickname` 建议去除首尾空格。
- 空字符串应视为非法输入并返回 `400`。

---

## 4. 后端实现要求

### 4.1 目录与文件

本步骤沿用 Step 1 规划的目录结构，补齐了 `services/`、`utils/`、`tests/` 目录。

实际变更文件如下：

| 路径 | 操作 | 说明 |
| ---- | ---- | ---- |
| `backend/app/exceptions.py` | **新增** | 统一业务异常 `AppException(status_code, code, message, details)` |
| `backend/app/main.py` | 补全 | 增加 `AppException` 处理器 + 增强 `RequestValidationError` 字段级映射 + Redis 生命周期 |
| `backend/app/api/v1/auth.py` | 补全 | 6 个认证端点的完整实现 |
| `backend/app/api/v1/router.py` | 未改 | `auth` 路由在 Step 1 已正确挂载 |
| `backend/app/schemas/auth.py` | 补全 | 增加 `SendCodeResponse`、`RefreshResponse`、`LogoutRequest`、`UserResponse`、`UpdateUserRequest`；`phone`/`code`/`nickname` 使用 Pydantic `field_validator` |
| `backend/app/dependencies.py` | 补全 | 实现 `get_current_user`，使用 `HTTPBearer(auto_error=False)` 手动返回 401 |
| `backend/app/utils/__init__.py` | **新增** | 包初始化 |
| `backend/app/utils/security.py` | **新增** | `create_access_token`、`create_refresh_token`、`decode_token`（python-jose） |
| `backend/app/services/__init__.py` | **新增** | 包初始化 |
| `backend/app/services/sms.py` | **新增** | 阿里云 Dypnsapi 封装，同步 SDK 通过 `asyncio.to_thread` 异步化 |
| `backend/app/services/redis.py` | **新增** | Redis 连接管理 + 验证码 / 频控 / 黑名单操作（`redis.asyncio`） |
| `backend/app/services/auth.py` | **新增** | `send_code`、`login`、`refresh_access_token`、`logout` 业务逻辑 |
| `backend/requirements.txt` | 补全 | 增加 `pytest>=8.0.0`、`pytest-asyncio>=0.23.0`、`aiosqlite>=0.20.0` |
| `backend/tests/__init__.py` | **新增** | 包初始化 |
| `backend/tests/conftest.py` | **新增** | SQLite 内存数据库 + mock Redis/SMS 的测试 fixtures |
| `backend/tests/test_auth.py` | **新增** | 12 个自动化测试用例 |

### 4.2 Schema 要求

`backend/app/schemas/auth.py` 至少应包含：

- `SendCodeRequest`
- `SendCodeResponse`
- `LoginRequest`
- `TokenResponse`
- `RefreshRequest`
- `RefreshResponse`
- `LogoutRequest`
- `UserResponse`
- `UpdateUserRequest`

要求：

- 手机号格式校验放在 schema 层。
- 验证码格式校验放在 schema 层。
- `UserResponse` 使用 ORM 模式，直接从 `User` 模型转换。
- `UpdateUserRequest` 在 Step 2 只暴露 `nickname`。

### 4.3 认证依赖

`get_current_user` 需要做到：

1. 解析 Bearer token。
2. 校验 token 类型必须是 `access`。
3. 解析出 user ID。
4. 查询数据库中的用户。
5. 按项目统一错误格式返回 `401`。

### 4.4 错误处理

实际实现采用 **`AppException` + 增强版 `RequestValidationError` 处理器** 两层机制：

1. **`AppException`**（`backend/app/exceptions.py`）：
   业务逻辑层抛出 `AppException(status_code, code, message)`，在 `main.py` 注册的全局处理器自动转换为 `{code, message, details}` JSON 响应。所有 `429 SMS_RATE_LIMITED`、`401 INVALID_REFRESH_TOKEN`、`502 SMS_SEND_FAILED` 等错误都走此通道。

2. **增强版 `RequestValidationError` 处理器**（`main.py`）：
   Schema 层的 Pydantic `field_validator` 校验失败后，处理器检查失败字段名并映射到业务错误码：
   - `phone` → `400 INVALID_PHONE`
   - `code` → `400 INVALID_VERIFY_CODE`
   - `nickname` → `400 INVALID_NICKNAME`
   - 其他 → `400 VALIDATION_ERROR`（保留原始 `details`）

   这样既遵守了"校验放在 schema 层"的要求，又保证了错误码与 API 规格一致。

注意事项：

- 认证接口**不使用** `HTTPException`；全部改为抛 `AppException`。
- 阿里云 SDK 异常在 `services/sms.py` 中被捕获并转换为 `AppException(502, "SMS_SEND_FAILED", ...)`。

---

## 5. Flutter 实现要求

### 5.1 登录页

登录页目标：

- 展示 Logo、标题、slogan。
- 提供手机号输入框。
- 提供验证码输入框。
- 提供“获取验证码”按钮与 60 秒倒计时。
- 提供登录按钮。
- 登录成功后进入主流程页。

交互要求：

- 手机号输入框只允许 11 位数字，可做友好格式化显示。
- 验证码输入框只允许 6 位数字。
- 手机号格式不合法时，不能发起发送验证码请求。
- 手机号与验证码都合法后，登录按钮才可点击。

### 5.2 认证状态管理

建议使用 Riverpod 管理认证状态，至少包含：

- 是否已登录。
- 当前用户信息。
- 登录中、发送验证码中、恢复登录中的加载状态。
- 登录失败、发送失败时的错误提示。

冷启动恢复登录建议流程：

1. 读取本地 `access_token` 与 `refresh_token`。
2. 若任一缺失，则视为未登录。
3. 若两者都存在，则调用 `/auth/me` 恢复当前用户。
4. 若 `/auth/me` 因 access token 失效返回 `401`，触发一次 `/auth/refresh`。
5. 刷新成功后重试 `/auth/me`。
6. 若仍失败，则清空本地登录态并回到 `/login`。

### 5.3 API 客户端

`frontend/lib/services/api_client.dart` 已补全，实现如下：

- `onRequest` 拦截器从 `SharedPreferences` 读取 `access_token` 并自动注入 `Authorization` 头。
- `onError` 拦截器处理 `401`：跳过 `/auth/refresh` 和 `/auth/login`；检查 `extra['_retried']` 防重入；使用独立 `Dio` 实例调用 refresh；成功则保存新 token 并重试原请求；失败则清空 token 并调用 `onForceLogout`。
- `onForceLogout`（`VoidCallback?`）由 `AuthNotifier` 设置，刷新失败时触发 auth 状态切换到 `unauthenticated`。

本步骤采用简单方案：

- 不要求处理并发 `401` 竞争。
- 不要求实现全局刷新锁。
- 只要求“单个失败请求 -> refresh -> 重试一次”闭环可用。

### 5.4 路由守卫

`frontend/lib/config/router.dart` 已补全。关键实现决策：

- **`routerProvider`**（`Provider<GoRouter>`）：路由不再是全局 `final router`，而是 Riverpod Provider，以便通过 `ref.read(authProvider)` 读取 auth 状态。
- **`_AuthRedirectNotifier`**（`ChangeNotifier`）：构造时通过 `ref.listen(authProvider, ...)` 监听 auth 变化，每次变化调用 `notifyListeners()`，作为 `GoRouter.refreshListenable` 触发 `redirect` 重新求值。
- `redirect` 逻辑：`AuthStatus.unknown` 不重定向；未登录且不在 `/login` 则跳 `/login`；已登录且在 `/login` 则跳 `/record`。
- `frontend/lib/app.dart` 从 `StatelessWidget` 改为 `ConsumerWidget`，通过 `ref.watch(routerProvider)` 获取路由实例。

### 5.5 配置入口

前端必须继续保持单一配置入口。

要求：

- 优先沿用 `frontend/lib/config/constants.dart` 里的 `baseUrl`。
- 如果要改名成 `app_config.dart`，必须替换旧入口，而不是让两套配置并存。
- 文档与代码里都不要鼓励写死真实服务器 IP。
- 真机联调优先通过 `--dart-define=BASE_URL=http://YOUR_SERVER_IP` 注入。

---

## 6. 实际变更文件清单

### 后端（新增）

- `backend/app/exceptions.py` — 统一业务异常 `AppException`
- `backend/app/utils/__init__.py`
- `backend/app/utils/security.py` — JWT 创建 / 解析
- `backend/app/services/__init__.py`
- `backend/app/services/redis.py` — Redis 连接管理 + 验证码 / 频控 / 黑名单
- `backend/app/services/sms.py` — 阿里云 Dypnsapi 封装
- `backend/app/services/auth.py` — 登录 / 刷新 / 登出业务逻辑
- `backend/tests/__init__.py`
- `backend/tests/conftest.py` — SQLite 内存数据库 + mock Redis/SMS fixtures
- `backend/tests/test_auth.py` — 12 个自动化测试

### 后端（补全 / 更新）

- `backend/app/main.py` — 增加 `AppException` 处理器 + 增强 `RequestValidationError` 字段映射 + Redis 生命周期
- `backend/app/api/v1/auth.py` — 6 个认证端点的完整实现
- `backend/app/schemas/auth.py` — 增加 `SendCodeResponse`、`RefreshResponse`、`LogoutRequest`、`UserResponse`、`UpdateUserRequest`
- `backend/app/dependencies.py` — 实现 `get_current_user`
- `backend/requirements.txt` — 增加 `pytest`、`pytest-asyncio`、`aiosqlite`

### 后端（未改动）

- `backend/app/api/v1/router.py` — Step 1 已正确挂载 `auth` 路由，无需改动
- `backend/app/config.py` — Step 1 已包含所有必要配置项

### 前端（新增）

- `frontend/lib/models/user.dart` — `User` 模型（`fromJson` / `toJson`）
- `frontend/lib/services/auth_service.dart` — 认证 API 调用 + token 持久化
- `frontend/lib/providers/auth_provider.dart` — `AuthNotifier`（Riverpod StateNotifier）

### 前端（补全 / 更新）

- `frontend/lib/services/api_client.dart` — 401 → refresh → 重试 + `onForceLogout`
- `frontend/lib/screens/auth/login_screen.dart` — 完整登录表单（ConsumerStatefulWidget）
- `frontend/lib/config/router.dart` — `routerProvider` + `_AuthRedirectNotifier` 路由守卫
- `frontend/lib/app.dart` — 从 `StatelessWidget` 改为 `ConsumerWidget`

### 前端（未改动）

- `frontend/lib/config/constants.dart` — 沿用 Step 1 配置入口

---

## 7. 测试要求

### 7.1 后端自动化测试

已使用 `pytest` + `pytest-asyncio` 实现，测试文件位于 `backend/tests/test_auth.py`（12 个用例，全部通过）。

覆盖场景：

1. `send-code` 成功返回 `200`，并写入验证码与频控 key。
2. 非法手机号返回 `400 INVALID_PHONE`。
3. 60 秒内重复发送返回 `429 SMS_RATE_LIMITED`。
4. 正确验证码可以登录，返回 tokens + user。
5. 错误验证码返回 `400 INVALID_VERIFY_CODE`。
6. 首次登录创建用户，再次登录返回同一用户。
7. `refresh` 返回新的 access token。
8. 已拉黑的 refresh token 返回 `401 INVALID_REFRESH_TOKEN`。
9. `logout` 将 refresh token 写入黑名单。
10. `GET /auth/me` 无 token 时返回 `401 INVALID_ACCESS_TOKEN`。
11. `PUT /auth/me` 更新昵称成功。
12. `PUT /auth/me` 空白昵称返回 `400 INVALID_NICKNAME`。

测试基础设施（`backend/tests/conftest.py`）：

- 数据库：SQLite 内存数据库（`aiosqlite`），通过猴子补丁让 `BigInteger` 在 SQLite 中渲染为 `INTEGER`（解决自增主键兼容性）。
- Redis：使用 `dict` 模拟，通过 `unittest.mock.patch` 替换 `app.services.redis` 的所有异步函数。
- SMS：`_mock_sms_send()` 辅助函数 mock `app.services.sms.send_verify_code`，返回预设验证码。
- HTTP 客户端：`httpx.AsyncClient` + `ASGITransport`。

运行命令：`cd backend && python -m pytest tests/ -v`

### 7.2 Swagger 验证

后端实现完成后，需要通过 `/docs` 手工验证：

1. `send-code`
2. `login`
3. `refresh`
4. `logout`
5. `me`

重点检查：

- 请求与响应字段名是否为 `snake_case`
- 错误结构是否统一
- 401/429/400 是否符合预期

### 7.3 Flutter 联调验证

至少完成以下联调：

1. 登录页可以发送验证码。
2. 输入正确验证码后可以登录进入主页面。
3. 登录后重启 APP 仍能恢复登录态。
4. 当 access token 失效时，能自动 refresh 并重试原请求。
5. refresh 失败时会清空本地登录态并回到登录页。

---

## 8. 验收标准

- [x] 后端 `POST /api/v1/auth/send-code` 已接入真实阿里云 Dypnsapi
- [x] `send-code` 成功时返回 `200` 和 `expire_seconds`
- [x] 60 秒内重复请求返回 `429`
- [x] 非法手机号返回 `400`
- [x] 后端 `POST /api/v1/auth/login` 能用正确验证码登录
- [x] 首次登录自动创建用户记录
- [x] 登录返回 `access_token`、`refresh_token`、`token_type`、`user`
- [x] 后端 `POST /api/v1/auth/refresh` 能刷新 access token
- [x] 被登出的 refresh token 不能再次调用 `refresh`
- [x] 后端 `POST /api/v1/auth/logout` 只作废当前提交的 refresh token
- [x] 后端 `GET /api/v1/auth/me` 需要有效 access token 才能访问
- [x] 后端 `PUT /api/v1/auth/me` 能更新昵称
- [x] 已补充后端重点自动化测试（12 个用例全部通过）
- [x] Flutter 登录页面已从占位页补全为真实表单
- [x] Flutter 可以完成发送验证码、登录、退出登录（代码已实现）
- [x] 登录后 token 已持久化到本地（SharedPreferences）
- [x] 重启 APP 可以恢复登录态（AuthNotifier._checkAuthStatus）
- [x] access token 过期后会自动刷新一次并重试原请求（Dio onError 拦截器）
- [x] refresh 失败后会清空本地登录态并回到 `/login`（onForceLogout → redirect）

> 注意：以上后端验收项已通过自动化测试验证。Flutter 联调验收需要启动服务后手动验证。

---

## 9. 给后续 Agent 的提醒

- Step 2 已完成实现。后续步骤的受保护接口使用 `Depends(get_current_user)`（来自 `app.dependencies`）获取当前用户。
- 业务错误统一使用 `AppException(status_code, code, message)`（来自 `app.exceptions`），不要用 `HTTPException`。
- 前端路由已改为 `routerProvider`（Riverpod Provider），不再是全局 `final router`。新增路由时在 `routerProvider` 内的 `routes` 列表中添加。
- 前端 `app.dart` 已改为 `ConsumerWidget`，后续如需修改根 Widget 请注意保持。
- 需要新增数据库模型时，`alembic` 迁移照常使用。Step 2 没有新增数据库表（`users` 表在 Step 1 已建好）。
- 阿里云 SMS 调用是同步 SDK 通过 `asyncio.to_thread` 异步化，后续如需调用其他阿里云服务可参考相同模式（见 `services/sms.py`）。
- 后端测试使用 SQLite 内存数据库，`BigInteger` 兼容性补丁在 `conftest.py` 中（monkey-patch `SQLiteTypeCompiler`），新增模型测试时无需重复处理。
