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

### 0.2 当前仓库状态

本步骤不是从零新建认证模块，而是在已有骨架上补全实现。

后端当前状态：

- `backend/app/api/v1/auth.py` 已存在，但仍是占位路由。
- `backend/app/schemas/auth.py` 已存在，但只有最基础的请求/响应模型。
- `backend/app/config.py` 已包含 JWT、Redis、阿里云短信相关配置项。
- `backend/app/dependencies.py` 已预留给通用依赖注入，但认证依赖尚未实现。
- `backend/app/services/` 与 `backend/app/utils/` 目标目录在 Step 1 文档中已规划；如果当前仓库里尚未创建，本步骤需要先补齐目录，再放入实现文件。

前端当前状态：

- `frontend/lib/services/api_client.dart` 已有 Dio 与 token 注入逻辑，但 `401 -> refresh` 仍未实现。
- `frontend/lib/config/router.dart` 已有主导航结构，但还没有登录态守卫。
- `frontend/lib/screens/auth/login_screen.dart` 仍是占位页面。
- `frontend/lib/config/constants.dart` 已作为统一配置入口存在；本步骤应沿用或等价替换它，不要再引入第二套并存的 `base_url` 配置。

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

- `RequestValidationError` 继续复用 Step 1 已有的统一错误转换逻辑，返回 `400`。
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

本步骤应优先沿用 Step 1 规划的目录结构。如果目标目录不存在，先创建目录，再补齐实现。

重点文件如下：

| 路径 | 操作 | 说明 |
| ---- | ---- | ---- |
| `backend/app/api/v1/auth.py` | 补全 | 把占位路由改成真实认证接口 |
| `backend/app/api/v1/router.py` | 核对 | 确认 `auth` 路由已正确挂载 |
| `backend/app/schemas/auth.py` | 补全 | 增加校验、响应模型、`LogoutRequest`、`UserResponse`、`UpdateUserRequest` |
| `backend/app/dependencies.py` | 补全 | 实现 `get_current_user` |
| `backend/app/utils/security.py` | 新增或补全 | JWT 生成、校验、过期时间处理 |
| `backend/app/services/sms.py` | 新增或补全 | 封装阿里云 Dypnsapi |
| `backend/app/services/redis.py` | 新增 | 验证码、频控、黑名单相关操作 |
| `backend/app/services/auth.py` | 新增或补全 | 登录、刷新、退出等业务逻辑集中处理 |
| `backend/tests/` 下的认证测试文件 | 新增 | 后端重点自动化测试 |

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

不要在认证接口里直接返回 FastAPI 默认错误结构。必须继续遵循项目统一格式。

特别注意：

- `RequestValidationError` 已在 Step 1 中统一处理，本步骤不要绕开它。
- 如果使用 `HTTPException(detail=...)`，需要保证最终响应体仍是 `code` / `message` / `details`。
- 阿里云异常不要原样抛给前端；应转换为项目内部错误码，例如 `SMS_SEND_FAILED`。

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

`frontend/lib/services/api_client.dart` 需要补全：

- 请求前自动注入 `Authorization`。
- 收到 `401` 时，如果本次请求不是 `/auth/refresh` 且尚未重试过，则尝试刷新一次 token。
- 刷新成功后重试原请求一次。
- 刷新失败后清空本地 token，并通知上层回到登录页。

本步骤采用简单方案：

- 不要求处理并发 `401` 竞争。
- 不要求实现全局刷新锁。
- 只要求“单个失败请求 -> refresh -> 重试一次”闭环可用。

### 5.4 路由守卫

`frontend/lib/config/router.dart` 需要补全登录态重定向：

- 未登录时，除 `/login` 外的页面都跳到 `/login`。
- 已登录时，访问 `/login` 自动跳到 `/record`。

### 5.5 配置入口

前端必须继续保持单一配置入口。

要求：

- 优先沿用 `frontend/lib/config/constants.dart` 里的 `baseUrl`。
- 如果要改名成 `app_config.dart`，必须替换旧入口，而不是让两套配置并存。
- 文档与代码里都不要鼓励写死真实服务器 IP。
- 真机联调优先通过 `--dart-define=BASE_URL=http://YOUR_SERVER_IP` 注入。

---

## 6. 需要补全或新增的文件

### 后端

- `backend/app/api/v1/auth.py`
- `backend/app/api/v1/router.py`
- `backend/app/schemas/auth.py`
- `backend/app/dependencies.py`
- `backend/app/utils/security.py`
- `backend/app/services/auth.py`
- `backend/app/services/sms.py`
- `backend/app/services/redis.py`
- `backend/tests/` 下的认证测试文件

### 前端

- `frontend/lib/services/api_client.dart`
- `frontend/lib/services/auth_service.dart`
- `frontend/lib/providers/auth_provider.dart`
- `frontend/lib/models/user.dart`
- `frontend/lib/screens/auth/login_screen.dart`
- `frontend/lib/config/router.dart`
- `frontend/lib/config/constants.dart` 或等价单一配置入口

---

## 7. 测试要求

### 7.1 后端自动化测试

Step 2 必须补充后端重点自动化测试，推荐使用 `pytest`。

自动化测试至少覆盖以下场景：

1. `send-code` 成功返回 `200`，并写入验证码与频控 key。
2. 非法手机号返回 `400`。
3. 60 秒内重复发送返回 `429`。
4. 正确验证码可以登录。
5. 错误或过期验证码返回 `400`。
6. 首次登录会创建用户记录。
7. `refresh` 对合法 refresh token 返回新的 access token。
8. 已拉黑的 refresh token 不能再次刷新。
9. `logout` 会拉黑当前 refresh token。
10. `GET /auth/me` 没有有效 access token 时返回 `401`。
11. `PUT /auth/me` 可以更新昵称。

测试约束：

- 自动化测试可以 mock 阿里云 SDK，不要求真实发短信。
- 自动化测试不应依赖真实公网短信服务。
- 自动化测试必须验证项目统一错误结构，而不仅是状态码。

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

- [ ] 后端 `POST /api/v1/auth/send-code` 已接入真实阿里云 Dypnsapi
- [ ] `send-code` 成功时返回 `200` 和 `expire_seconds`
- [ ] 60 秒内重复请求返回 `429`
- [ ] 非法手机号返回 `400`
- [ ] 后端 `POST /api/v1/auth/login` 能用正确验证码登录
- [ ] 首次登录自动创建用户记录
- [ ] 登录返回 `access_token`、`refresh_token`、`token_type`、`user`
- [ ] 后端 `POST /api/v1/auth/refresh` 能刷新 access token
- [ ] 被登出的 refresh token 不能再次调用 `refresh`
- [ ] 后端 `POST /api/v1/auth/logout` 只作废当前提交的 refresh token
- [ ] 后端 `GET /api/v1/auth/me` 需要有效 access token 才能访问
- [ ] 后端 `PUT /api/v1/auth/me` 能更新昵称
- [ ] 已补充后端重点自动化测试
- [ ] Flutter 登录页面已从占位页补全为真实表单
- [ ] Flutter 可以完成发送验证码、登录、退出登录
- [ ] 登录后 token 已持久化到本地
- [ ] 重启 APP 可以恢复登录态
- [ ] access token 过期后会自动刷新一次并重试原请求
- [ ] refresh 失败后会清空本地登录态并回到 `/login`

---

## 9. 给后续 Agent 的提醒

- 先看本文件，再看 `docs/00-global-rules.md` 和 Step 1 文档中的骨架约定。
- 遇到阿里云账号、短信签名、模板、联调环境不一致时，先停下来确认，不要私自改成 mock 流程。
- 这一步的目标是“稳定可跑通的 MVP 认证闭环”，不要把精力扩散到头像上传、微信登录、复杂会话管理或并发刷新优化。
