# Step 2: 认证模块

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL 技术栈。本步骤在 Step 1 的项目骨架基础上实现手机号登录认证。

**前置依赖**: Step 1 已完成，项目骨架已搭建，数据库已创建。

---

## 本步骤目标

1. 后端实现短信验证码发送与验证 API
2. 后端实现 JWT Token 认证机制
3. 后端实现登录/自动注册逻辑
4. Flutter 实现登录页面 UI
5. Flutter 实现 Token 持久化与自动登录

---

## 1. 认证流程

```
用户输入手机号 → 请求发送验证码 → 后端调用阿里云SMS发送 → Redis存储验证码(5分钟过期)
    ↓
用户输入验证码 → 请求登录 → 后端验证Redis中的验证码
    ↓ 验证成功
检查手机号是否已注册 → 未注册则自动创建用户 → 生成JWT Token对返回
    ↓
Flutter 保存 Token → 进入主页
```

---

## 2. 后端 API 规格

本步骤默认沿用 Step 1 中的全局约定:
- 接口字段统一使用 `snake_case`
- 业务错误统一为 `code` + `message` + `details`
- 输入不合法统一返回 `400`
- 客户端通过统一入口访问 `/api/...`

### 2.1 发送验证码

```
POST /api/v1/auth/send-code
Content-Type: application/json
```

请求体:
```json
{
  "phone": "13800138000"
}
```

成功响应 (200):
```json
{
  "expire_seconds": 300
}
```

错误响应 (429 - 60秒内重复请求):
```json
{
  "code": "SMS_RATE_LIMITED",
  "message": "请求过于频繁，请60秒后再试",
  "details": {
    "retry_after_seconds": 60
  }
}
```

业务逻辑:
- 验证手机号格式 (中国大陆手机号, 11位数字, 1开头)
- 检查 Redis 中是否有 60 秒内发送过的记录 (防刷)
- 调用阿里云 Dypnsapi `SendSmsVerifyCode` API 发送短信 (验证码由 API 自动生成)
- API 返回验证码明文 (ReturnVerifyCode=true)，将验证码存入 Redis，key 为 `sms:verify:{phone}`，过期时间 5 分钟
- 同时设置频率限制 key `sms:limit:{phone}`，过期时间 60 秒
- **开发阶段**: 如果阿里云 SMS 未配置，将验证码打印到控制台，方便测试

### 2.2 手机号登录

```
POST /api/v1/auth/login
Content-Type: application/json
```

请求体:
```json
{
  "phone": "13800138000",
  "code": "123456"
}
```

成功响应 (200):
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

错误响应 (400):
```json
{
  "code": "INVALID_VERIFY_CODE",
  "message": "验证码错误或已过期",
  "details": null
}
```

业务逻辑:
- 从 Redis 获取验证码并验证
- 验证成功后删除 Redis 中的验证码 (一次性使用)
- 查询 users 表，手机号存在则登录，不存在则自动创建用户
- 生成 Access Token (2小时过期) 和 Refresh Token (30天过期)
- 返回 Token 和用户信息

### 2.3 刷新 Token

```
POST /api/v1/auth/refresh
Content-Type: application/json
```

请求体:
```json
{
  "refresh_token": "eyJhbGciOiJIUzI1NiIs..."
}
```

成功响应 (200):
```json
{
  "access_token": "eyJhbGciOiJIUzI1NiIs...",
  "token_type": "bearer"
}
```

业务逻辑:
- 验证 Refresh Token 有效性
- 检查 Token 是否在黑名单中 (Redis)
- 生成新的 Access Token
- 返回新 Token

### 2.4 退出登录

```
POST /api/v1/auth/logout
Authorization: Bearer {access_token}
Content-Type: application/json
```

请求体:
```json
{
  "refresh_token": "eyJhbGciOiJIUzI1NiIs..."
}
```

成功响应 (204): No Content

业务逻辑:
- 校验当前 access_token
- 将本次登录对应的 refresh_token 加入 Redis 黑名单，直到其自然过期
- 仅作废当前设备提交的 refresh_token，不影响其他设备

### 2.5 获取当前用户信息

```
GET /api/v1/auth/me
Authorization: Bearer {access_token}
```

成功响应 (200):
```json
{
  "id": 1,
  "phone": "13800138000",
  "nickname": "用户昵称",
  "avatar_url": "https://..."
}
```

### 2.6 更新用户信息

```
PUT /api/v1/auth/me
Authorization: Bearer {access_token}
Content-Type: application/json
```

请求体:
```json
{
  "nickname": "新昵称"
}
```

---

## 3. 后端实现要点

### 3.1 JWT 工具 (`app/utils/security.py`)

```python
from datetime import datetime, timedelta
from jose import jwt, JWTError
from app.config import settings

def create_access_token(user_id: int) -> str:
    expire = datetime.utcnow() + timedelta(minutes=settings.ACCESS_TOKEN_EXPIRE_MINUTES)
    payload = {
        "sub": str(user_id),
        "exp": expire,
        "type": "access"
    }
    return jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)

def create_refresh_token(user_id: int) -> str:
    expire = datetime.utcnow() + timedelta(days=settings.REFRESH_TOKEN_EXPIRE_DAYS)
    payload = {
        "sub": str(user_id),
        "exp": expire,
        "type": "refresh"
    }
    return jwt.encode(payload, settings.JWT_SECRET_KEY, algorithm=settings.JWT_ALGORITHM)

def verify_token(token: str, token_type: str = "access") -> int | None:
    """验证 Token 并返回 user_id，无效返回 None"""
    try:
        payload = jwt.decode(token, settings.JWT_SECRET_KEY, algorithms=[settings.JWT_ALGORITHM])
        if payload.get("type") != token_type:
            return None
        user_id = int(payload.get("sub"))
        return user_id
    except (JWTError, ValueError):
        return None
```

### 3.2 认证依赖注入 (`app/dependencies.py`)

```python
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from sqlalchemy.ext.asyncio import AsyncSession
from app.database import get_db
from app.utils.security import verify_token
from app.models.user import User

security = HTTPBearer()

async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    db: AsyncSession = Depends(get_db),
) -> User:
    user_id = verify_token(credentials.credentials)
    if user_id is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={
                "code": "INVALID_ACCESS_TOKEN",
                "message": "无效的认证凭据",
                "details": None,
            },
        )
    user = await db.get(User, user_id)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={
                "code": "USER_NOT_FOUND",
                "message": "用户不存在",
                "details": None,
            },
        )
    return user
```

### 3.3 阿里云短信认证服务 (`app/services/sms.py`)

使用阿里云**号码认证服务 (Dypnsapi)** 的 `SendSmsVerifyCode` API 发送验证码短信。

**API 关键信息:**
- **接口**: `SendSmsVerifyCode` (号码认证服务 Dypnsapi 2017-05-25)
- **Endpoint**: `dypnsapi.aliyuncs.com`
- **AccessKey**: 通过环境变量注入，例如 `YOUR_ALIYUN_ACCESS_KEY_ID` / `YOUR_ALIYUN_ACCESS_KEY_SECRET`
- **签名名称**: `速通互联验证码` (系统赠送签名，必须搭配系统赠送模板)
- **模板 CODE**: `100001` (系统赠送模板)
- **验证码生成**: TemplateParam 中使用 `##code##` 占位符，由 API 自动生成验证码
- **返回验证码**: 设置 `ReturnVerifyCode=true`，响应中会返回生成的验证码

**请求参数说明:**

| 参数 | 值 | 说明 |
|------|------|------|
| PhoneNumber | 用户手机号 | 必填 |
| SignName | 速通互联验证码 | 系统赠送签名 |
| TemplateCode | 100001 | 系统赠送模板 |
| TemplateParam | `{"code":"##code##"}` | ##code## 由系统自动替换为验证码 |
| CodeType | 1 | 纯数字验证码 |
| CodeLength | 6 | 6位验证码 |
| ValidTime | 300 | 验证码有效期300秒(5分钟) |
| Interval | 60 | 发送间隔60秒(频控) |
| DuplicatePolicy | 1 | 覆盖旧验证码 |
| ReturnVerifyCode | true | 响应中返回验证码明文 |

**成功响应示例:**
```json
{
  "Code": "OK",
  "Message": "成功",
  "Success": true,
  "Model": {
    "VerifyCode": "423256",
    "BizId": "112231421412414124123^4",
    "RequestId": "a3671ccf-0102-4c8e-8797-a3678e091d09"
  }
}
```

**常见错误码:**

| HTTP Status | 错误码 | 说明 |
|---|---|---|
| 400 | MOBILE_NUMBER_ILLEGAL | 手机号格式错误 |
| 400 | BUSINESS_LIMIT_CONTROL | 触发号码天级流控 |
| 400 | FREQUENCY_FAIL | 频控校验未通过 (60秒内重发) |
| 400 | INVALID_PARAMETERS | 非法参数 |
| 400 | FUNCTION_NOT_OPENED | 没有开通融合认证功能 |

**实现代码:**

```python
from alibabacloud_dypnsapi20170525.client import Client
from alibabacloud_tea_openapi.models import Config
from alibabacloud_dypnsapi20170525.models import SendSmsVerifyCodeRequest
from app.config import settings
import json

class SMSService:
    def __init__(self):
        if settings.ALIYUN_ACCESS_KEY_ID and settings.ALIYUN_ACCESS_KEY_SECRET:
            config = Config(
                access_key_id=settings.ALIYUN_ACCESS_KEY_ID,
                access_key_secret=settings.ALIYUN_ACCESS_KEY_SECRET,
                endpoint="dypnsapi.aliyuncs.com",
            )
            self.client = Client(config)
        else:
            self.client = None

    async def send_verification_code(self, phone: str) -> tuple[bool, str | None]:
        """
        发送短信验证码。
        返回 (是否成功, 验证码明文 or None)。
        验证码由阿里云 API 自动生成，通过 ReturnVerifyCode=true 返回。
        """
        if self.client is None:
            import random
            code = str(random.randint(100000, 999999))
            print(f"[DEV SMS] 手机号: {phone}, 验证码: {code}")
            return True, code

        request = SendSmsVerifyCodeRequest(
            phone_number=phone,
            sign_name=settings.ALIYUN_SMS_SIGN_NAME,
            template_code=settings.ALIYUN_SMS_TEMPLATE_CODE,
            template_param=json.dumps({"code": "##code##"}),
            code_type=1,          # 纯数字
            code_length=6,        # 6位
            valid_time=300,       # 5分钟有效
            interval=60,          # 60秒频控
            duplicate_policy=1,   # 覆盖旧验证码
            return_verify_code=True,
        )

        try:
            response = self.client.send_sms_verify_code(request)
            if response.body.code == "OK" and response.body.success:
                verify_code = response.body.model.verify_code
                return True, verify_code
            else:
                print(f"[SMS Error] Code: {response.body.code}, Message: {response.body.message}")
                return False, None
        except Exception as e:
            print(f"[SMS Exception] {e}")
            return False, None

sms_service = SMSService()
```

**注意**: 需要安装阿里云号码认证服务 SDK:
```
pip install alibabacloud-dypnsapi20170525
```

**与之前方案的区别:**
- 使用 `Dypnsapi` (号码认证服务) 而非 `Dysmsapi` (短信服务)
- 验证码由 API 自动生成，不需要后端手动生成
- API 内置频控 (Interval=60秒)，但后端仍需用 Redis 做频控以防绕过
- API 返回验证码明文，后端存入 Redis 用于后续校验

### 3.4 Redis 工具

```python
import redis.asyncio as aioredis
from app.config import settings

redis_client = aioredis.from_url(settings.REDIS_URL, decode_responses=True)

async def set_verify_code(phone: str, code: str):
    await redis_client.set(f"sms:verify:{phone}", code, ex=300)  # 5分钟

async def get_verify_code(phone: str) -> str | None:
    return await redis_client.get(f"sms:verify:{phone}")

async def delete_verify_code(phone: str):
    await redis_client.delete(f"sms:verify:{phone}")

async def check_sms_rate_limit(phone: str) -> bool:
    """返回 True 表示可以发送，False 表示被限流"""
    key = f"sms:limit:{phone}"
    if await redis_client.exists(key):
        return False
    await redis_client.set(key, "1", ex=60)  # 60秒限流
    return True

async def blacklist_refresh_token(token: str, expires_seconds: int):
    await redis_client.set(f"auth:refresh:blacklist:{token}", "1", ex=expires_seconds)

async def is_refresh_token_blacklisted(token: str) -> bool:
    return bool(await redis_client.exists(f"auth:refresh:blacklist:{token}"))
```

### 3.5 Pydantic Schema (`app/schemas/auth.py`)

```python
from pydantic import BaseModel, field_validator
import re

class SendCodeRequest(BaseModel):
    phone: str

    @field_validator("phone")
    @classmethod
    def validate_phone(cls, v):
        if not re.match(r"^1[3-9]\d{9}$", v):
            raise ValueError("手机号格式不正确")
        return v

class LoginRequest(BaseModel):
    phone: str
    code: str

    @field_validator("code")
    @classmethod
    def validate_code(cls, v):
        if not re.match(r"^\d{6}$", v):
            raise ValueError("验证码必须是6位数字")
        return v

class RefreshTokenRequest(BaseModel):
    refresh_token: str

class LogoutRequest(BaseModel):
    refresh_token: str

class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    user: "UserResponse"

class UserResponse(BaseModel):
    id: int
    phone: str
    nickname: str | None
    avatar_url: str | None

    class Config:
        from_attributes = True

class UpdateUserRequest(BaseModel):
    nickname: str | None = None
```

---

## 4. Flutter 登录页面

### 4.1 登录流程 UI

```
┌─────────────────────────────────┐
│                                 │
│         🐾 当当日记              │
│       记录毛孩子的每一天          │
│                                 │
│  ┌─────────────────────────┐    │
│  │ 📱 请输入手机号           │    │
│  └─────────────────────────┘    │
│                                 │
│  ┌──────────────┐ ┌────────┐   │
│  │ 请输入验证码   │ │获取验证码│   │
│  └──────────────┘ └────────┘   │
│       (获取后显示 59s 倒计时)     │
│                                 │
│  ┌─────────────────────────┐    │
│  │         登  录            │    │
│  └─────────────────────────┘    │
│                                 │
│   登录即表示同意《用户协议》       │
│                                 │
└─────────────────────────────────┘
```

### 4.2 页面设计要点

- 顶部留白，展示 APP Logo 和 slogan
- 手机号输入框: 限制11位数字，自动格式化显示 (138 0013 8000)
- 验证码输入框 + 获取验证码按钮在同一行
- 获取验证码按钮: 点击后变为灰色，显示 60 秒倒计时
- 登录按钮: 手机号和验证码都填写后才可点击 (主题色)
- 整体风格: 圆角输入框，温暖色调

### 4.3 API 调用服务 (`services/api_client.dart`)

```dart
import 'package:dio/dio.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_config.dart';

class ApiClient {
  late Dio _dio;

  ApiClient() {
    _dio = Dio(BaseOptions(
      baseUrl: '${AppConfig.baseUrl}/api/v1',
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 10),
    ));

    _dio.interceptors.add(InterceptorsWrapper(
      onRequest: (options, handler) async {
        // 自动注入 Token
        final prefs = await SharedPreferences.getInstance();
        final token = prefs.getString('access_token');
        if (token != null) {
          options.headers['Authorization'] = 'Bearer $token';
        }
        handler.next(options);
      },
      onError: (error, handler) async {
        // 401 时尝试刷新 Token
        if (error.response?.statusCode == 401) {
          final success = await _refreshToken();
          if (success) {
            // 重试原请求
            final retryResponse = await _dio.fetch(error.requestOptions);
            handler.resolve(retryResponse);
            return;
          }
          // 刷新失败，跳转登录页
          // 通过全局事件通知跳转
        }
        handler.next(error);
      },
    ));
  }

  Future<bool> _refreshToken() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final refreshToken = prefs.getString('refresh_token');
      if (refreshToken == null) return false;

      final response = await Dio(BaseOptions(baseUrl: '${AppConfig.baseUrl}/api/v1')).post(
        '/auth/refresh',
        data: {'refresh_token': refreshToken},
      );
      final newAccessToken = response.data['access_token'];
      await prefs.setString('access_token', newAccessToken);
      return true;
    } catch (_) {
      return false;
    }
  }

  Dio get dio => _dio;
}
```

### 4.4 认证状态管理 (`providers/auth_provider.dart`)

使用 Riverpod 管理认证状态:
- `authStateProvider`: 监听认证状态 (未认证/已认证)
- `loginProvider`: 处理登录逻辑
- 应用启动时检查本地 Token 是否存在且有效
- Token 过期自动刷新，刷新失败跳转登录页

### 4.5 路由守卫

```dart
// 未登录时所有页面重定向到登录页
// 已登录时登录页重定向到首页
redirect: (context, state) {
  final isLoggedIn = ref.read(authStateProvider);
  final isLoginRoute = state.matchedLocation == '/login';

  if (!isLoggedIn && !isLoginRoute) return '/login';
  if (isLoggedIn && isLoginRoute) return '/record';
  return null;
}
```

---

## 5. 开发阶段的测试方式

开发阶段:
1. 后端未配置 SMS AccessKey Secret 时，验证码在控制台打印 (开发模式)
2. 建议通过环境变量开关启用开发模式，不要把万能验证码直接写死到正式逻辑中
3. 后端 Swagger 文档 (`/docs`) 可以直接测试 API
4. 阿里云签名和模板使用系统赠送的，无需等待审核

---

## 6. 需要创建/修改的文件清单

### 后端
- `backend/app/utils/security.py` - JWT 工具 (新建)
- `backend/app/services/sms.py` - 短信服务 (新建)
- `backend/app/services/redis.py` - Redis 工具 (新建)
- `backend/app/schemas/auth.py` - 认证 Schema (新建)
- `backend/app/api/v1/auth.py` - 认证路由 (新建)
- `backend/app/api/v1/router.py` - 添加 auth 路由
- `backend/app/dependencies.py` - 添加认证依赖
- `backend/requirements.txt` - 添加 `alibabacloud-dypnsapi20170525`

### 前端
- `frontend/lib/services/api_client.dart` - API 客户端 (新建)
- `frontend/lib/services/auth_service.dart` - 认证服务 (新建)
- `frontend/lib/providers/auth_provider.dart` - 认证状态 (新建)
- `frontend/lib/screens/auth/login_screen.dart` - 登录页 (新建)
- `frontend/lib/config/app_config.dart` - 开发环境配置入口 (新建)
- `frontend/lib/config/router.dart` - 添加路由守卫
- `frontend/lib/models/user.dart` - 用户模型 (新建)

---

## 7. 验收标准

- [ ] 后端 `POST /api/v1/auth/send-code` 能发送验证码 (开发模式下打印到控制台)
- [ ] 60 秒内重复请求返回 429
- [ ] 后端 `POST /api/v1/auth/login` 能用正确验证码登录
- [ ] 首次登录自动创建用户记录
- [ ] 登录返回 access_token 和 refresh_token
- [ ] 后端 `GET /api/v1/auth/me` 需要有效 Token 才能访问
- [ ] 后端 `POST /api/v1/auth/refresh` 能刷新 Token
- [ ] 后端 `POST /api/v1/auth/logout` 能作废当前设备的 refresh_token
- [ ] Flutter 登录页面 UI 正确展示
- [ ] Flutter 输入手机号+验证码可以成功登录
- [ ] 登录后 Token 持久化到本地
- [ ] 重启 APP 自动登录 (Token 有效时)
- [ ] Token 过期自动尝试刷新
