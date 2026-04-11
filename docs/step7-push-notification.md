# Step 7: 推送提醒 (驱虫到期通知)

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL 技术栈。本步骤实现驱虫到期推送提醒功能。

**前置依赖**: Step 5 已完成 (驱虫管理)，驱虫记录和周期设置功能可用。

---

## 本步骤目标

1. 后端集成极光推送 (JPush) SDK
2. 后端实现定时任务，每天 10:00 扫描需要推送的驱虫提醒
3. Flutter 集成 JPush SDK，接收推送通知
4. Flutter 处理推送通知点击事件 (跳转到驱虫管理页面)

---

## 1. 推送规则

### 驱虫提醒规则

- **提醒条件**: 用户设置了驱虫周期 且 有驱虫记录
- **提前提醒**: 下次驱虫日期前 **3 天**开始推送
- **过期提醒**: 驱虫日期过期后**每天**继续推送
- **停止条件**: 用户记录了新的驱虫 (新记录日期 >= 上次提醒计算的到期日期)
- **推送时间**: 每天上午 **10:00**
- **内驱和外驱分别计算和推送**

### 推送内容

提前提醒:
```
标题: 驱虫提醒 🐾
内容: [宠物名字] 距离下次[内驱/外驱]还有X天，请及时驱虫哦～
```

过期提醒:
```
标题: 驱虫提醒 🐾
内容: [宠物名字] 的[内驱/外驱]已过期X天，请尽快驱虫！
```

---

## 2. 极光推送 (JPush) 集成

### 2.1 注册流程

1. 注册极光推送账号: https://www.jiguang.cn/
2. 创建应用，获取:
   - AppKey (客户端和服务端都需要)
   - Master Secret (仅服务端使用)
3. 在极光后台配置 Android 推送:
   - 上传应用包名 (com.dangdang.dangdang_diary)

### 2.2 工作原理

```
Flutter APP 启动 → 注册 JPush SDK → 获取 Registration ID
    ↓
APP 将 Registration ID 上报给后端
    ↓
后端存储 user_id ↔ registration_id 映射
    ↓
后端定时任务 → 查询需要提醒的用户 → 调用 JPush REST API 推送
    ↓
JPush 服务器 → 推送到用户手机
```

---

## 3. 后端实现

### 3.1 数据库扩展

在 users 表添加字段 (或创建新的 user_devices 表):

```python
class UserDevice(Base):
    __tablename__ = "user_devices"

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(BigInteger, ForeignKey("users.id"), nullable=False, index=True)
    registration_id: Mapped[str] = mapped_column(String(200), nullable=False)
    platform: Mapped[str] = mapped_column(String(20), nullable=False)  # "android" / "ios"
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow, onupdate=datetime.utcnow)
```

需要创建 Alembic 迁移。

### 3.2 注册设备 API

```
POST /api/v1/devices/register
Authorization: Bearer {access_token}
Content-Type: application/json
```

请求体:
```json
{
  "registration_id": "1a0018970aba7ef5641",
  "platform": "android"
}
```

成功响应 (200):
```json
{
  "message": "设备注册成功"
}
```

业务逻辑:
- 如果 user_id + platform 已存在记录，更新 registration_id
- 否则创建新记录
- 一个用户可以有多个设备

### 3.3 JPush 推送服务 (`app/services/push.py`)

```python
import httpx
import base64
from app.config import settings

class PushService:
    JPUSH_API_URL = "https://api.jpush.cn/v3/push"

    def __init__(self):
        auth_str = f"{settings.JPUSH_APP_KEY}:{settings.JPUSH_MASTER_SECRET}"
        self.auth_header = base64.b64encode(auth_str.encode()).decode()

    async def push_to_user(
        self,
        registration_ids: list[str],
        title: str,
        content: str,
        extras: dict | None = None,
    ) -> bool:
        """推送消息给指定用户设备"""
        if not registration_ids:
            return False

        payload = {
            "platform": "all",
            "audience": {
                "registration_id": registration_ids
            },
            "notification": {
                "android": {
                    "alert": content,
                    "title": title,
                    "extras": extras or {}
                },
                "ios": {
                    "alert": {
                        "title": title,
                        "body": content
                    },
                    "extras": extras or {}
                }
            },
            "options": {
                "apns_production": not settings.DEBUG
            }
        }

        async with httpx.AsyncClient() as client:
            try:
                response = await client.post(
                    self.JPUSH_API_URL,
                    json=payload,
                    headers={
                        "Authorization": f"Basic {self.auth_header}",
                        "Content-Type": "application/json"
                    },
                    timeout=10.0,
                )
                if response.status_code == 200:
                    return True
                else:
                    print(f"[JPush Error] {response.status_code}: {response.text}")
                    return False
            except Exception as e:
                print(f"[JPush Exception] {e}")
                return False

push_service = PushService()
```

### 3.4 定时任务 (`app/tasks/reminders.py`)

```python
from apscheduler.schedulers.asyncio import AsyncIOScheduler
from datetime import date, timedelta
from sqlalchemy import select
from app.database import async_session_maker
from app.models import Pet, PetMember, Deworming, UserDevice
from app.models.deworming import DewormingType
from app.services.push import push_service

scheduler = AsyncIOScheduler()

async def check_deworming_reminders():
    """每天10:00执行，检查所有宠物的驱虫提醒"""
    async with async_session_maker() as db:
        # 查询所有设置了驱虫周期的宠物
        pets = await db.execute(
            select(Pet).where(
                (Pet.internal_deworming_cycle_days.isnot(None)) |
                (Pet.external_deworming_cycle_days.isnot(None))
            )
        )
        pets = pets.scalars().all()

        today = date.today()

        for pet in pets:
            # 检查内驱
            if pet.internal_deworming_cycle_days:
                await _check_and_push(
                    db, pet, DewormingType.INTERNAL,
                    pet.internal_deworming_cycle_days, today
                )
            # 检查外驱
            if pet.external_deworming_cycle_days:
                await _check_and_push(
                    db, pet, DewormingType.EXTERNAL,
                    pet.external_deworming_cycle_days, today
                )

async def _check_and_push(
    db, pet: Pet, deworming_type: DewormingType,
    cycle_days: int, today: date
):
    """检查单个宠物的单种驱虫是否需要提醒"""
    # 获取最后一次驱虫记录
    result = await db.execute(
        select(Deworming)
        .where(
            Deworming.pet_id == pet.id,
            Deworming.deworming_type == deworming_type,
        )
        .order_by(Deworming.dewormed_at.desc())
        .limit(1)
    )
    last_record = result.scalar_one_or_none()
    if not last_record:
        return

    next_due = last_record.dewormed_at + timedelta(days=cycle_days)
    days_diff = (next_due - today).days  # 正=还剩, 负=已过期

    type_name = "内驱" if deworming_type == DewormingType.INTERNAL else "外驱"

    # 判断是否需要推送 (到期前3天 或 已过期)
    if days_diff > 3:
        return  # 还早，不用提醒

    if days_diff >= 0:
        title = "驱虫提醒 🐾"
        content = f"{pet.name} 距离下次{type_name}还有{days_diff}天，请及时驱虫哦～"
    else:
        title = "驱虫提醒 🐾"
        content = f"{pet.name} 的{type_name}已过期{abs(days_diff)}天，请尽快驱虫！"

    # 获取该宠物所有关联用户的设备
    members = await db.execute(
        select(PetMember.user_id).where(PetMember.pet_id == pet.id)
    )
    user_ids = [m.user_id for m in members.scalars().all()]

    devices = await db.execute(
        select(UserDevice.registration_id).where(
            UserDevice.user_id.in_(user_ids)
        )
    )
    reg_ids = [d.registration_id for d in devices.scalars().all()]

    if reg_ids:
        await push_service.push_to_user(
            registration_ids=reg_ids,
            title=title,
            content=content,
            extras={
                "type": "deworming_reminder",
                "pet_id": str(pet.id),
            }
        )

# 注册定时任务
def setup_scheduler():
    scheduler.add_job(
        check_deworming_reminders,
        'cron',
        hour=10,
        minute=0,
        id='deworming_reminder',
        replace_existing=True,
    )
    scheduler.start()
```

### 3.5 在 FastAPI lifespan 中启动定时任务

```python
# app/main.py
from app.tasks.reminders import setup_scheduler

@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_scheduler()
    yield
    # scheduler.shutdown() 在退出时自动清理
```

---

## 4. Flutter 集成

### 4.1 JPush Flutter 插件

```yaml
# pubspec.yaml
dependencies:
  jpush_flutter: ^2.7.0
```

### 4.2 初始化 JPush (`services/push_service.dart`)

```dart
import 'package:jpush_flutter/jpush_flutter.dart';
import 'api_client.dart';

class PushNotificationService {
  final JPush _jpush = JPush();
  final ApiClient _apiClient;

  PushNotificationService(this._apiClient);

  Future<void> initialize() async {
    _jpush.setup(
      appKey: "YOUR_JPUSH_APP_KEY",
      channel: "developer-default",
      production: false,  // 开发环境
      debug: true,
    );

    // 获取 Registration ID
    _jpush.getRegistrationID().then((rid) {
      if (rid != null && rid.isNotEmpty) {
        _registerDevice(rid);
      }
    });

    // 监听推送消息
    _jpush.addEventHandler(
      onReceiveNotification: (Map<String, dynamic> message) async {
        print("收到推送: $message");
      },
      onOpenNotification: (Map<String, dynamic> message) async {
        // 用户点击推送通知
        _handleNotificationClick(message);
      },
      onReceiveMessage: (Map<String, dynamic> message) async {
        // 自定义消息 (非通知栏)
      },
    );
  }

  Future<void> _registerDevice(String registrationId) async {
    try {
      await _apiClient.dio.post('/devices/register', data: {
        'registration_id': registrationId,
        'platform': 'android',  // 或通过 Platform.isIOS 判断
      });
    } catch (e) {
      print("设备注册失败: $e");
    }
  }

  void _handleNotificationClick(Map<String, dynamic> message) {
    final extras = message['extras'] as Map?;
    if (extras == null) return;

    final type = extras['type'];
    if (type == 'deworming_reminder') {
      final petId = extras['pet_id'];
      // 导航到驱虫管理页面
      // 通过全局导航 key 或事件总线实现
    }
  }
}
```

### 4.3 Android 配置

`android/app/build.gradle` 中需要添加 JPush 的配置:

```groovy
android {
    defaultConfig {
        manifestPlaceholders = [
            JPUSH_PKGNAME: applicationId,
            JPUSH_APPKEY: "YOUR_JPUSH_APP_KEY",
            JPUSH_CHANNEL: "developer-default",
        ]
    }
}
```

`android/app/src/main/AndroidManifest.xml` 中确保有推送所需的权限:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
```

### 4.4 推送权限请求

Android 13+ 需要运行时请求通知权限:

```dart
import 'package:permission_handler/permission_handler.dart';

Future<void> requestNotificationPermission() async {
  final status = await Permission.notification.status;
  if (status.isDenied) {
    await Permission.notification.request();
  }
}
```

在用户首次登录后请求权限。

---

## 5. 测试方案

### 5.1 后端定时任务测试

开发阶段可以:
1. 添加一个手动触发的 API 端点用于测试:

```python
@router.post("/debug/trigger-reminders")
async def trigger_reminders():
    """仅开发环境可用"""
    await check_deworming_reminders()
    return {"message": "已触发驱虫提醒检查"}
```

2. 在 APScheduler 中临时设置为每分钟执行一次，验证后改回 10:00

### 5.2 推送测试

1. 可以在极光推送后台手动发送测试推送
2. 使用 curl 直接调用 JPush API 测试
3. APP 安装到真机测试 (模拟器可能收不到推送)

---

## 6. 需要创建/修改的文件清单

### 后端
- `backend/app/models/user_device.py` - 用户设备模型 (新建)
- `backend/app/models/__init__.py` - 导入 UserDevice (修改)
- `backend/app/services/push.py` - JPush 推送服务 (新建)
- `backend/app/tasks/reminders.py` - 定时提醒任务 (新建)
- `backend/app/api/v1/devices.py` - 设备注册路由 (新建)
- `backend/app/api/v1/router.py` - 注册 devices 路由 (修改)
- `backend/app/main.py` - 添加定时任务启动 (修改)
- `backend/alembic/versions/xxx_add_user_devices.py` - 数据库迁移 (自动生成)
- `backend/requirements.txt` - 确认 httpx 已包含 (检查)

### 前端
- `frontend/pubspec.yaml` - 添加 jpush_flutter 依赖 (修改)
- `frontend/lib/services/push_service.dart` - 推送服务 (新建)
- `frontend/lib/main.dart` - 初始化推送服务 (修改)
- `frontend/android/app/build.gradle` - JPush 配置 (修改)
- `frontend/android/app/src/main/AndroidManifest.xml` - 推送权限 (修改)

---

## 7. 验收标准

- [ ] 后端用户设备 API 可以注册/更新设备 Registration ID
- [ ] 后端定时任务正确计算驱虫到期状态
- [ ] 后端定时任务在到期前 3 天开始推送
- [ ] 后端定时任务在过期后每天推送
- [ ] 后端推送消息内容包含宠物名字和驱虫类型
- [ ] 后端推送发送到宠物档案的所有关联用户
- [ ] Flutter 正确初始化 JPush SDK
- [ ] Flutter 登录后上报 Registration ID 到后端
- [ ] Flutter 在手机通知栏正确收到推送消息
- [ ] Flutter 点击推送通知可以跳转到对应宠物的驱虫管理页面
- [ ] Android 13+ 正确请求通知权限
- [ ] 用户记录新的驱虫后，提醒停止 (直到下次周期到期)
