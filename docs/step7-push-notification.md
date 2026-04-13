# Step 7: 推送提醒 (驱虫到期本地通知)

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL 技术栈。本步骤实现驱虫到期本地推送提醒功能。

**前置依赖**: Step 5 已完成 (驱虫管理)，驱虫记录和周期设置功能可用。

---

## 本步骤目标

1. Flutter 集成 `flutter_local_notifications` 插件
2. APP 启动/进入后台时，从后端获取驱虫状态，计算并调度本地通知
3. 用户记录新驱虫后，重新调度通知
4. 点击通知跳转到对应宠物的驱虫管理页面

---

## 1. 方案说明

**为什么用本地推送而不是外部推送服务 (如极光推送)?**

- 驱虫提醒是周期性、可预测的通知，不需要服务端实时触发
- 本地推送无需注册第三方推送服务，零成本
- 减少后端复杂度，不需要维护设备注册表和推送定时任务
- APP 只在开启/后台时才能触发本地通知，对于宠物日记场景足够（用户定期打开 APP 记录时即可收到提醒）

**限制:**

- APP 被完全杀死 (Force Stop) 后无法触发通知，需要下次打开 APP 时补发
- 如果用户长时间不打开 APP，则无法收到提醒

---

## 2. 推送规则

### 驱虫提醒规则

- **提醒条件**: 用户设置了驱虫周期 且 有驱虫记录
- **提前提醒**: 下次驱虫日期前 **3 天**开始推送
- **过期提醒**: 驱虫日期过期后显示过期提醒
- **停止条件**: 用户记录了新的驱虫
- **内驱和外驱分别计算和推送**
- **调度原则**: 每次只安排“下一次需要触发的通知”，APP 启动、恢复前台或记录新驱虫后重新计算，避免重复使用过期文案

### 通知内容

提前提醒:
```
标题: 驱虫提醒
内容: [宠物名字] 距离下次[内驱/外驱]还有X天，请及时驱虫哦～
```

过期提醒:
```
标题: 驱虫提醒
内容: [宠物名字] 的[内驱/外驱]已过期X天，请尽快驱虫！
```

---

## 3. Flutter 实现

### 3.1 依赖

```yaml
# pubspec.yaml
dependencies:
  flutter_local_notifications: ^18.0.0
  timezone: ^0.9.0
  permission_handler: ^11.3.0
```

### 3.2 通知服务 (`services/notification_service.dart`)

```dart
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

class NotificationService {
  static final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  static Future<void> initialize() async {
    tz_data.initializeTimeZones();

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );
  }

  static void _onNotificationTapped(NotificationResponse response) {
    final payload = response.payload;
    if (payload != null) {
      // 解析 payload，跳转到对应宠物的驱虫管理页面
      // payload 格式: "deworming:{pet_id}"
      // 通过全局导航 key 实现页面跳转
    }
  }

  /// 调度驱虫提醒通知
  static Future<void> scheduleDewormingReminder({
    required int notificationId,
    required String petName,
    required String dewormingType, // "内驱" / "外驱"
    required int daysRemaining,    // 正=剩余天数, 负=过期天数
    required int petId,
  }) async {
    String title = "驱虫提醒";
    String body;
    final scheduledBody = "$petName 的$dewormingType提醒已到，请打开当当日记查看最新状态。";

    if (daysRemaining > 0) {
      body = "$petName 距离下次$dewormingType还有${daysRemaining}天，请及时驱虫哦～";
    } else if (daysRemaining == 0) {
      body = "$petName 今天该做$dewormingType了，请及时驱虫哦～";
    } else {
      body = "$petName 的$dewormingType已过期${daysRemaining.abs()}天，请尽快驱虫！";
    }

    const androidDetails = AndroidNotificationDetails(
      'deworming_reminder',
      '驱虫提醒',
      channelDescription: '宠物驱虫到期提醒通知',
      importance: Importance.high,
      priority: Priority.high,
    );
    const details = NotificationDetails(android: androidDetails);

    final now = tz.TZDateTime.now(tz.local);

    // 已进入提醒窗口时，先立即提示一次
    if (daysRemaining <= 3) {
      await _plugin.show(
        notificationId,
        title,
        body,
        details,
        payload: "deworming:$petId",
      );
    }

    // 只调度下一次提醒，避免每天重复使用过时文案
    final shouldScheduleFutureReminder = daysRemaining > 3;
    final shouldScheduleTomorrowReminder = daysRemaining >= 0 && daysRemaining <= 3;

    if (shouldScheduleFutureReminder || shouldScheduleTomorrowReminder) {
      final offsetDays = shouldScheduleFutureReminder ? daysRemaining - 3 : 1;
      final targetDate = now.add(Duration(days: offsetDays));
      final nextReminder = tz.TZDateTime(
        tz.local,
        targetDate.year,
        targetDate.month,
        targetDate.day,
        10,
        0,
      );

      await _plugin.zonedSchedule(
        notificationId + 1000,
        title,
        scheduledBody,
        nextReminder,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: "deworming:$petId",
      );
    }
  }

  /// 取消指定宠物的驱虫提醒
  static Future<void> cancelDewormingReminder(int notificationId) async {
    await _plugin.cancel(notificationId);
    await _plugin.cancel(notificationId + 1000);
  }

  /// 取消所有通知
  static Future<void> cancelAll() async {
    await _plugin.cancelAll();
  }
}
```

### 3.3 驱虫提醒调度逻辑 (`services/deworming_reminder_scheduler.dart`)

```dart
class DewormingReminderScheduler {
  final ApiClient _apiClient;

  DewormingReminderScheduler(this._apiClient);

  /// APP 启动/恢复时调用，刷新所有宠物的驱虫提醒
  Future<void> refreshAllReminders() async {
    // 先取消所有旧通知
    await NotificationService.cancelAll();

    // 获取所有宠物档案
    final pets = await PetService(_apiClient).getPets();

    for (final pet in pets) {
      // 获取每个宠物的驱虫状态
      final status = await HealthService(_apiClient).getDewormingStatus(pet.id);

      // 调度内驱提醒
      if (status.internal.daysRemaining != null) {
        await NotificationService.scheduleDewormingReminder(
          notificationId: pet.id * 10 + 1, // 内驱 ID
          petName: pet.name,
          dewormingType: "内驱",
          daysRemaining: status.internal.daysRemaining!,
          petId: pet.id,
        );
      }

      // 调度外驱提醒
      if (status.external.daysRemaining != null) {
        await NotificationService.scheduleDewormingReminder(
          notificationId: pet.id * 10 + 2, // 外驱 ID
          petName: pet.name,
          dewormingType: "外驱",
          daysRemaining: status.external.daysRemaining!,
          petId: pet.id,
        );
      }
    }
  }
}
```

### 3.4 集成到 APP 生命周期

```dart
// main.dart
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await NotificationService.initialize();
  runApp(const MyApp());
}

// app.dart - 监听 APP 生命周期
class _AppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refreshReminders();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // APP 从后台恢复时刷新提醒
      _refreshReminders();
    }
  }

  Future<void> _refreshReminders() async {
    // 仅在已登录状态下刷新
    if (isLoggedIn) {
      final scheduler = DewormingReminderScheduler(apiClient);
      await scheduler.refreshAllReminders();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
```

### 3.5 记录驱虫后刷新通知

在驱虫记录成功后，重新调度该宠物的通知:

```dart
// 在 deworming_tab.dart 中，记录驱虫成功后
Future<void> _onDewormingRecorded() async {
  // ... 记录成功后 ...
  // 重新刷新该宠物的驱虫提醒
  final scheduler = DewormingReminderScheduler(apiClient);
  await scheduler.refreshAllReminders();
}
```

---

## 4. Android 配置

### 4.1 权限

`android/app/src/main/AndroidManifest.xml` 中添加:
```xml
<uses-permission android:name="android.permission.POST_NOTIFICATIONS"/>
<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>
<uses-permission android:name="android.permission.SCHEDULE_EXACT_ALARM"/>
```

### 4.2 通知权限请求

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

## 5. 后端变更

### 5.1 移除 JPush 相关代码

本方案不再需要:
- ~~`backend/app/models/user_device.py`~~ - 不需要设备注册表
- ~~`backend/app/services/push.py`~~ - 不需要 JPush 推送服务
- ~~`backend/app/tasks/reminders.py`~~ 中的推送逻辑 - 不需要后端推送
- ~~`backend/app/api/v1/devices.py`~~ - 不需要设备注册 API

### 5.2 保留后端驱虫状态 API

`GET /api/v1/pets/{pet_id}/deworming-status` API 保持不变 (Step 5 中已定义)，Flutter 端调用此 API 获取驱虫状态数据后，在本地调度通知。

---

## 6. 需要创建/修改的文件清单

### 前端
- `frontend/pubspec.yaml` - 添加 `flutter_local_notifications`, `timezone` 依赖 (修改)
- `frontend/lib/services/notification_service.dart` - 本地通知服务 (新建)
- `frontend/lib/services/deworming_reminder_scheduler.dart` - 驱虫提醒调度 (新建)
- `frontend/lib/main.dart` - 初始化通知服务 (修改)
- `frontend/lib/app.dart` - 添加生命周期监听 (修改)
- `frontend/lib/screens/health/deworming_tab.dart` - 记录后刷新通知 (修改)
- `frontend/android/app/src/main/AndroidManifest.xml` - 通知权限 (修改)

### 后端
- 无新增文件，保持 Step 5 的驱虫状态 API 不变

---

## 7. 验收标准

- [ ] Flutter 正确初始化 `flutter_local_notifications`
- [ ] APP 启动后，自动从后端获取驱虫状态并调度本地通知
- [ ] 驱虫到期前 3 天收到本地推送通知
- [ ] 驱虫过期后显示过期通知
- [ ] 通知内容包含宠物名字和驱虫类型（内驱/外驱）
- [ ] 点击通知可以跳转到对应宠物的驱虫管理页面
- [ ] 用户记录新驱虫后，通知重新调度
- [ ] APP 从后台恢复时刷新提醒状态
- [ ] Android 13+ 正确请求通知权限
- [ ] 无驱虫周期设置或无驱虫记录时不触发通知
