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
  "message": "验证码已发送",
  "expire_seconds": 300
}
```

错误响应 (429 - 60秒内重复请求):
```json
{
  "detail": "请求过于频繁，请60秒后再试"
}
```

业务逻辑:
- 验证手机号格式 (中国大陆手机号, 11位数字, 1开头)
- 检查 Redis 中是否有 60 秒内发送过的记录 (防刷)
- 生成 6 位随机数字验证码
- 调用阿里云 SMS API 发送短信
- 将验证码存入 Redis，key 为 `sms:verify:{phone}`，过期时间 5 分钟
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

错误响应 (401):
```json
{
  "detail": "验证码错误或已过期"
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

### 2.4 获取当前用户信息

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

### 2.5 更新用户信息

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
            detail="无效的认证凭据",
        )
    user = await db.get(User, user_id)
    if user is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="用户不存在",
        )
    return user
```

### 3.3 阿里云 SMS 服务 (`app/services/sms.py`)

```python
from alibabacloud_dysmsapi20170525.client import Client
from alibabacloud_tea_openapi.models import Config
from alibabacloud_dysmsapi20170525.models import SendSmsRequest
from app.config import settings
import json

class SMSService:
    def __init__(self):
        if settings.ALIYUN_SMS_ACCESS_KEY_ID:
            config = Config(
                access_key_id=settings.ALIYUN_SMS_ACCESS_KEY_ID,
                access_key_secret=settings.ALIYUN_SMS_ACCESS_KEY_SECRET,
                endpoint="dysmsapi.aliyuncs.com",
            )
            self.client = Client(config)
        else:
            self.client = None

    async def send_verification_code(self, phone: str, code: str) -> bool:
        if self.client is None:
            # 开发模式: 打印验证码到控制台
            print(f"[DEV SMS] 手机号: {phone}, 验证码: {code}")
            return True

        request = SendSmsRequest(
            phone_numbers=phone,
            sign_name=settings.ALIYUN_SMS_SIGN_NAME,
            template_code=settings.ALIYUN_SMS_TEMPLATE_CODE,
            template_param=json.dumps({"code": code}),
        )
        response = self.client.send_sms(request)
        return response.body.code == "OK"

sms_service = SMSService()
```

注意: 需要额外安装 `alibabacloud-dysmsapi20170525` 包:
```
pip install alibabacloud-dysmsapi20170525
```

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

class ApiClient {
  static const String baseUrl = 'http://YOUR_SERVER_IP:8000/api/v1';

  late Dio _dio;

  ApiClient() {
    _dio = Dio(BaseOptions(
      baseUrl: baseUrl,
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

      final response = await Dio(BaseOptions(baseUrl: baseUrl)).post(
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

由于阿里云 SMS 需要审核，开发阶段:
1. 后端未配置 SMS Key 时，验证码打印到控制台
2. 可以硬编码一个万能验证码 (如 `000000`)，方便测试
3. 后端 Swagger 文档 (`/docs`) 可以直接测试 API

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
- `backend/requirements.txt` - 添加 `alibabacloud-dysmsapi20170525`

### 前端
- `frontend/lib/services/api_client.dart` - API 客户端 (新建)
- `frontend/lib/services/auth_service.dart` - 认证服务 (新建)
- `frontend/lib/providers/auth_provider.dart` - 认证状态 (新建)
- `frontend/lib/screens/auth/login_screen.dart` - 登录页 (新建)
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
- [ ] Flutter 登录页面 UI 正确展示
- [ ] Flutter 输入手机号+验证码可以成功登录
- [ ] 登录后 Token 持久化到本地
- [ ] 重启 APP 自动登录 (Token 有效时)
- [ ] Token 过期自动尝试刷新
