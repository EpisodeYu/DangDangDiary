# Optimization Step 4 · Pet 角色变更的 silent sync（修复"被赋权后不刷新看不到"的 bug）

> 状态：✅ 已落地（2026-05-23）。
> - `PetListNotifier.silentRefresh()` + `_petListResultEquals` 已加入 `lib/providers/pet_provider.dart`
> - `lib/utils/api_error.dart` 新建，统一 `isPermissionError`
> - `lib/app.dart` 在 `AppLifecycleState.resumed` 时调用 `silentRefresh()`
> - `pet_edit_screen.dart`（编辑模式）/`pet_manage_screen.dart`（已升级为 ConsumerStatefulWidget）`initState` 触发 silentRefresh
> - `pet_share_detail_screen.dart::_changeRole` 成功后 silentRefresh（多设备一致性）
> - `timeline_screen.dart` / `photo_viewer_screen.dart` / `record_screen.dart` / `pet_edit_screen.dart` 中的写操作 catch DioException 时按 `isPermissionError` 分流，命中即 silentRefresh + 提示 "权限已更新，请重试"
> - 由 `_isPermissionError` 派生的私有 helper 全部清理掉
>
> ⚠️ **未做（按"按需"原则推迟）**：`lib/screens/health/*` 10 个屏幕中的 add/edit/delete 写操作仍然走"保存失败: $e"老文案，未接入 silentRefresh + "权限已更新，请重试"统一文案。原因：本期 step4 核心目标是修首页编辑权限感知 bug，health 模块的 owner 撤权场景在 UI 上仍能工作（仅文案不友好），可作为后续小型 cleanup 跟进。
>
> ⚠️ 由于本仓库未装 Flutter SDK，**未跑 `flutter analyze` / `flutter test`**，仅做了 import / 语法 / 类型层面的人工 review 与 ReadLints。**双账号 owner→viewer→editor 升降级实机联调需要人测**（见 §7 验证清单）。

## 1. 背景与现象

复现步骤：

1. A（owner） 在「档案分享」页把 B 的角色从 viewer → editor。后端 `update_member_role` 成功，B 在 `PetMember` 表的 role 立刻变成 `editor`。
2. B 此时 App 还停留在某个页面（任一非档案分享列表页都行），并未主动下拉刷新。
3. B 进入「宠物档案 → 选这只宠物 → 编辑」页面，看到的角色徽章仍是 viewer，所有输入框只读、保存按钮不显示。
4. B 必须在「宠物档案管理」页手动下拉刷新，或退出登录重进，才能拿到新 role。

根因：

- `frontend/lib/providers/pet_provider.dart` 中 `PetListNotifier.build()` 通过 `ref.watch(authProvider)` 只在登录态变化时重建；不会因为远端 PetMember 表变化而 invalidate。
- `petListProvider` 全局 cache 一份 `PetListResult`，所有页面（record、timeline、health、pet_manage、pet_edit、share_detail）都读它。
- 任何主动 `refresh()` 都会 `state = const AsyncLoading();` → 整个 pet list 短暂为空 → 依赖它的 UI 全部进入 loading / 空态闪烁，用户体验差，所以本来就不愿意频繁调。

## 2. 目标

- **静默同步**：当远端 role 变化时，前端能在合适时机自动 fetch，并且**不让任何依赖 petListProvider 的页面进入 AsyncLoading**。
- **零页面闪动**：UI 上只看到 role badge / save 按钮的可见性"无缝切换"，列表本身不重建（不闪头像）。
- 覆盖三个常见触发时机：进入编辑页前 / App 回到前台 / 写操作收到 403 时。
- 不引入推送 / 轮询 / 长连接。后端 0 改动。

## 3. 已决策

| 决策点 | 选定方案 | 理由 |
|--------|----------|------|
| 刷新方式 | 软刷新（silentRefresh）：后台 fetch，**不进入** `AsyncLoading`，拿到新数据后 diff 决定是否替换 state | 避免 UI 抖动 |
| diff 维度 | `(id, role, share_code_active, name, breed, birthday, avatar_url, owner_id, updated_at)` 任一不同即视为变化 | role + share_code_active 是 step4 的主诉求；其余字段顺便保证 owner 改名也能静默同步 |
| 触发点 | a) 编辑页 `initState` / `didChangeDependencies`；b) App 由 background → resumed；c) 任何写操作收到 `403` 或业务码 `PET_EDITOR_REQUIRED` / `PET_OWNER_REQUIRED` | 覆盖最常见三类路径 |
| 静默失败处理 | 失败时记 debug log，不弹错；下一次触发点再试 | 不打扰用户 |
| 是否在每次进入 pet manage 列表也 silentRefresh | 是 | 用户从 share detail 回到 manage 列表时也希望看到最新 role badge |
| 是否要新增后端单 pet 详情接口 | **否**（本期） | `GET /api/v1/pets?page=1&page_size=100` 已经够用；引入单 pet 详情接口在改动量、provider 切片、缓存一致性上都是大改，不在本期 scope |

未来若 pet 数量 > 100 或单 pet 频繁刷新场景增多，再单独立项做 `GET /api/v1/pets/{id}` + 局部 merge。本期先按"整表替换 + diff"做。

## 4. 修改清单

### 4.1 前端

| 文件 | 改动 |
|------|------|
| `frontend/lib/providers/pet_provider.dart` | `PetListNotifier` 新增 `silentRefresh()`；新增 `_petListResultEquals(a, b)` 用于 diff |
| `frontend/lib/app.dart` | `didChangeAppLifecycleState(AppLifecycleState.resumed)` 内调 `silentRefresh()` |
| `frontend/lib/screens/profile/pet_edit_screen.dart` | `initState` 末尾安排一次 post-frame silentRefresh（仅 `_isEditing` 时） |
| `frontend/lib/screens/profile/pet_manage_screen.dart` | 进入列表时（首次 build）触发 silentRefresh（仅一次，借助 `ref.listen` 或 `ConsumerStatefulWidget` 的 `initState`） |
| `frontend/lib/screens/profile/share/pet_share_detail_screen.dart` | 现有 `initState` 中的 `petListProvider.refresh()` 改为 `silentRefresh()`（如果有调用；当前是 share code / members 刷新，pet list 没刷，但当 role 在该页改完时手动也应 silentRefresh，详见 §5.5） |
| `frontend/lib/utils/api_error.dart` （新建） | `bool isPermissionError(Object e)` 判断 `DioException` + `code in {PET_EDITOR_REQUIRED, PET_OWNER_REQUIRED}` 或 `statusCode == 403` |
| 各写操作入口（见 §5.6 表格） | 在 catch 到 403 / 权限错时调用 `silentRefresh()` 并提示 "权限已更新，请重试" |

### 4.2 后端

**无改动**。

## 5. 详细步骤

### 5.1 `lib/providers/pet_provider.dart`

完整重写后的核心片段：

```dart
final petListProvider =
    AsyncNotifierProvider<PetListNotifier, PetListResult>(PetListNotifier.new);

class PetListNotifier extends AsyncNotifier<PetListResult> {
  /// True when a silentRefresh is currently in flight; used to dedupe
  /// rapid fire triggers (e.g. resumed + initState 同帧触发).
  bool _silentRefreshInFlight = false;

  @override
  Future<PetListResult> build() async {
    final authState = ref.watch(authProvider);
    if (authState.status != AuthStatus.authenticated) {
      return PetListResult(page: 1, pageSize: 0, total: 0, pets: []);
    }
    final service = ref.read(petServiceProvider);
    return await service.getPets(page: 1, pageSize: 100);
  }

  /// Hard refresh: 把 state 翻到 AsyncLoading 再 fetch。仅用于用户
  /// 明确发起的下拉刷新（pet manage 页面 / share detail 页面）。
  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() async {
      final service = ref.read(petServiceProvider);
      return await service.getPets(page: 1, pageSize: 100);
    });
  }

  /// Silent refresh: 后台 fetch，**不进入 AsyncLoading**，只有当
  /// (id, role, share_code_active, name, breed, birthday, avatar_url,
  ///  is_owner, updated_at) 与当前 state 有差异时才替换 state。
  /// 失败时静默 log，不抛、不改 state。
  ///
  /// 触发时机：
  ///   - 进入编辑页 / share detail 页前
  ///   - App 从后台回到前台
  ///   - 写操作收到 PET_*_REQUIRED 或 HTTP 403
  Future<void> silentRefresh() async {
    if (_silentRefreshInFlight) return;
    final authState = ref.read(authProvider);
    if (authState.status != AuthStatus.authenticated) return;
    _silentRefreshInFlight = true;
    try {
      final service = ref.read(petServiceProvider);
      final fresh = await service.getPets(page: 1, pageSize: 100);
      final current = state.valueOrNull;
      if (current == null) {
        // 第一次 fetch 还没回来时，silentRefresh 落地不应该改 state
        // (state 已经是 AsyncLoading 中)，让 build() 自然完成即可。
        return;
      }
      if (_petListResultEquals(current, fresh)) {
        if (kDebugMode) debugPrint('[petListProvider] silentRefresh: no diff');
        return;
      }
      if (kDebugMode) debugPrint('[petListProvider] silentRefresh: applied diff');
      state = AsyncData(fresh);
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('[petListProvider] silentRefresh failed (ignored): $e\n$st');
      }
      // 静默失败：保持现状，下次触发再试
    } finally {
      _silentRefreshInFlight = false;
    }
  }
}

/// 单纯按"展示态字段"做相等比较——不比较 reminder cycle 等纯本地编辑字段，
/// 那些字段是 owner 自己改，本人 App 内已经实时拿到的；这里只关心：是否需要
/// 重新渲染 pet list / pet badge / 编辑权限。
bool _petListResultEquals(PetListResult a, PetListResult b) {
  if (a.total != b.total) return false;
  if (a.pets.length != b.pets.length) return false;
  // 服务端按 created_at desc 稳定排序，这里假设顺序对齐即可。
  for (var i = 0; i < a.pets.length; i++) {
    final pa = a.pets[i];
    final pb = b.pets[i];
    if (pa.id != pb.id) return false;
    if (pa.name != pb.name) return false;
    if (pa.petType != pb.petType) return false;
    if (pa.breed != pb.breed) return false;
    if (pa.birthday != pb.birthday) return false;
    if (pa.avatarUrl != pb.avatarUrl) return false;
    if (pa.isOwner != pb.isOwner) return false;
    if (pa.myRole != pb.myRole) return false;
    if (pa.shareCodeActive != pb.shareCodeActive) return false;
    if (pa.updatedAt != pb.updatedAt) return false;
    // 顺手把可能在 owner 端被改的几个 reminder 字段也比一下，
    // 避免 owner 在另一台设备改完 viewer 端也想看到。
    if (pa.internalDewormingCycleDays != pb.internalDewormingCycleDays) return false;
    if (pa.externalDewormingCycleDays != pb.externalDewormingCycleDays) return false;
    if (pa.combinedDewormingCycleDays != pb.combinedDewormingCycleDays) return false;
    if (pa.bathCycleDays != pb.bathCycleDays) return false;
    if (pa.nailTrimCycleDays != pb.nailTrimCycleDays) return false;
    if (pa.groomingCycleDays != pb.groomingCycleDays) return false;
  }
  return true;
}
```

> **关键不变量**：`state = AsyncData(fresh)` 这一行只会在 diff 失败时触发，等价于 Flutter 视角下"pet list 没变就完全不通知 listener"。Riverpod 的 AsyncNotifier 内部会按引用相等检测 listener 重建，加上我们这里直接换 `AsyncData(fresh)` 实例，所有依赖的页面都会收到一次 rebuild —— 但因为 `valueOrNull` 的 pets 列表内每个 Pet 的 `==` 现状是默认 identity 比较，仍然会 rebuild。
>
> 这无关紧要：rebuild 不等于 loading，UI 不会闪——`CachedNetworkImage` 等 widget 都按 URL 比较，不会重新发请求；ListView 也按 itemBuilder 复用 element。**真正会让用户感知到的"列表清空 → loading → 再来"**这一过程仅由 `AsyncLoading` 触发，silentRefresh 路径下不会发生。

### 5.2 `lib/app.dart` 修改 `didChangeAppLifecycleState`

在现有 resumed 分支末尾加一行 silentRefresh：

```dart
@override
void didChangeAppLifecycleState(AppLifecycleState state) {
  if (state == AppLifecycleState.resumed) {
    ApiClient().resetConnectionPool();
    _maybeRefreshReminders();
    _tryHandlePendingPayload();
    // Opt Step 4: 后台拉一遍 pet list，权限 / 角色 / 头像若有变化则静默更新。
    final auth = ref.read(authProvider);
    if (auth.status == AuthStatus.authenticated) {
      ref.read(petListProvider.notifier).silentRefresh();
    }
  }
}
```

### 5.3 `lib/screens/profile/pet_edit_screen.dart`

`initState` 末尾追加一次 silentRefresh（仅编辑模式才需要——新建模式根本没有 role 概念）：

```dart
@override
void initState() {
  super.initState();
  if (_isEditing) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(petListProvider.notifier).silentRefresh();
    });
  }
}
```

> 当前文件继承 `ConsumerState<PetEditScreen>`，已经能在 build 中读 ref。如果项目当前没有 `initState`（看 `_PetEditScreenState` 实际只 override 了 `dispose` / `build`），加 `initState` 即可，不要破坏 `_initFromPet` 在 build 中初始化的逻辑。

### 5.4 `lib/screens/profile/pet_manage_screen.dart`

把当前的 `ConsumerWidget` 升级为 `ConsumerStatefulWidget`，在 `initState` 末尾安排一次 post-frame silentRefresh：

```dart
class PetManageScreen extends ConsumerStatefulWidget {
  const PetManageScreen({super.key});
  @override
  ConsumerState<PetManageScreen> createState() => _PetManageScreenState();
}

class _PetManageScreenState extends ConsumerState<PetManageScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(petListProvider.notifier).silentRefresh();
    });
  }

  @override
  Widget build(BuildContext context) {
    // 现有逻辑保持不变
    final petListAsync = ref.watch(petListProvider);
    // ...
  }
}
```

> 注意：现有 `RefreshIndicator(onRefresh: () => ref.read(petListProvider.notifier).refresh())` 这一硬刷新**保持不变**——它是用户手动下拉，让他看一下 spinner 是 OK 的，符合直觉。

### 5.5 `lib/screens/profile/share/pet_share_detail_screen.dart`

owner 在该页修改某成员 role 后，自己设备上对应的 pet list 中那条 pet 的 `share_code_active` / member 数等都不变（owner 自己的 role 也没变），所以**当前不强求**在该页改完后调 silentRefresh。但为了"哪怕另一个 owner 同时改了什么"也能 catch 到，把 `_changeRole` / `_confirmRemove` 调完后追加一次 silentRefresh：

```dart
Future<void> _changeRole(BuildContext context, SharedMember m, PetRole role) async {
  try {
    await ref
        .read(sharedMembersProvider(widget.petId).notifier)
        .updateRole(m.userId, role);
    // 自己 owner 的 pet badge 不会变，但顺手 silentRefresh 一下，
    // 让多设备 / 多 owner 场景下保持一致。
    ref.read(petListProvider.notifier).silentRefresh();
    // ... 现有 SnackBar
  } catch (e) {
    // ... 现有错误处理
  }
}
```

### 5.6 写操作收到 403 时 silentRefresh + 重试提示

新建 `lib/utils/api_error.dart`：

```dart
import 'package:dio/dio.dart';

bool isPermissionError(Object error) {
  if (error is! DioException) return false;
  final data = error.response?.data;
  if (data is Map) {
    final code = data['code'];
    if (code == 'PET_EDITOR_REQUIRED' || code == 'PET_OWNER_REQUIRED') {
      return true;
    }
  }
  return error.response?.statusCode == 403;
}
```

在所有受影响的写操作 catch 块中统一处理：

| 文件 | 入口 | 触发时机 |
|------|------|----------|
| `lib/screens/timeline/timeline_screen.dart` | `_deleteSingle` / `_deleteSelected` | catch DioException 时若 `isPermissionError`，加 `ref.read(petListProvider.notifier).silentRefresh();` 并把 SnackBar 文案改为「权限已更新，请重试」 |
| `lib/screens/timeline/photo_viewer_screen.dart` | `_deletePhoto` | 同上 |
| `lib/screens/record/record_screen.dart` | `_submit` catch DioException | 同上（"权限已更新，请重试"） |
| `lib/screens/profile/pet_edit_screen.dart` | `_save` catch | 同上 |
| `lib/screens/health/...` 中所有写操作 catch | 体重 / 驱虫 / 疫苗 / 日常的 add / edit / delete catch DioException | 同上（按需，agent 看实际文件清单） |

示例 patch（以 `timeline_screen.dart::_deleteSinglePhoto` 为例）：

```dart
Future<void> _deleteSinglePhoto(int photoId) async {
  final service = ref.read(_photoServiceProvider);
  try {
    await service.deletePhoto(photoId);
    if (!mounted) return;
    ref.read(timelineProvider.notifier).removePhotos([photoId]);
    _showSnack('已删除');
  } on DioException catch (e) {
    if (!mounted) return;
    if (isPermissionError(e)) {
      // 静默拉一遍 pet list，下次再点删除时 UI 已经能正确显示无权限按钮
      ref.read(petListProvider.notifier).silentRefresh();
      _showSnack('权限已更新，请重试');
    } else {
      _showSnack(_deleteErrorMessage(e));
    }
  } catch (_) {
    if (!mounted) return;
    _showSnack('删除失败，请稍后重试');
  }
}
```

> 复用 `isPermissionError` 后，`_isPermissionError(e)` 这种私有 helper 也可以删除，让所有页面统一调 `api_error.dart` 里的版本。

### 5.7 已经写好的"硬刷新"调用是否需要批量改成 silentRefresh？

按以下原则：

- 用户**主动下拉刷新** / **用户主动点重试按钮** / **用户刚执行了完成态较强的操作（如添加宠物 / 删除宠物 / 编辑保存）** → 仍然用 `refresh()`（硬刷新），让 spinner 出现是 OK 的。
- 上述 §5.2 / 5.3 / 5.4 / 5.5 / 5.6 列出的所有"被动触发"场景 → 一律 `silentRefresh()`。

具体不改 `refresh()` 的地方：
- `pet_manage_screen.dart` 的 `RefreshIndicator.onRefresh`
- `pet_edit_screen.dart` `_save` 成功后的 `ref.read(petListProvider.notifier).refresh()`
- `pet_edit_screen.dart` `_redeem` 成功后的 `ref.read(petListProvider.notifier).refresh()`
- `pet_edit_screen.dart` `_pickAndUploadAvatar` 成功后的 `ref.read(petListProvider.notifier).refresh()`
- `pet_share_list_screen.dart` 的 `RefreshIndicator.onRefresh`
- `pet_edit_screen.dart` `_confirmAndLeave` / `_confirmAndDelete` 成功后

这些操作都是"用户刚做了什么，看到 spinner 心里有底"，硬刷新更符合直觉。

## 6. 数据 & API 兼容性

- 无后端协议变更。
- `petListProvider` API 新增 `silentRefresh()`，不影响现有调用。
- 任何 `valueOrNull` 在 silentRefresh 期间都保持非 null，不会引入新的空判断需求。

## 7. 验证清单

**双账号联调**（推荐 1 台手机 + 1 个模拟器 / 另一台手机）：

1. A 创建宠物 X，B 通过分享码加入为 viewer。
2. B 进入 X 的「编辑」页：右上是 viewer badge，输入框只读，无保存按钮。
3. **不退出 B 的页面**，让 A 在 share detail 中把 B 改为 editor。
4. B 当场返回到 pet manage 列表 → 进入 X 编辑：**直接** 看到 editor badge，输入框可编辑，保存按钮出现。无任何"列表清空 → loading"的闪动。
5. 重新 4 一次但路径变成：B 把 App 切到后台 → 切回前台 → 列表正常显示无闪动，badge 已变成 editor。
6. 边界：B 处在「编辑」页时 A 把 B 改为 editor → B **未离开页面**，UI 上仍是 viewer（这是合理的——`PetEditScreen._initFromPet` 只在 `_isInitialized=false` 时 init）。B 退出该页再进，看到 editor。这是当前 scope 的可接受表现。
7. B 在 viewer 状态下硬点「上传一张照片」（如果 record 页还能进的话）→ 服务端 403 → SnackBar 显示「权限已更新，请重试」，pet list 已经 silentRefresh，再次进入编辑页可见。

**回归**：

1. 单账号纯粹用 App 不切换：所有页面表现与改动前完全一致，silentRefresh 在 App resumed 时调用 1 次但 diff 无变化，UI 无变化。
2. 网络断开时 App resumed → silentRefresh fail → 静默吞掉，不弹错误。
3. 登出再登录 → `build()` 重新走，所有页面正常加载。

## 8. 风险与回退

- **风险 1**：silentRefresh 在 `resumed` + `pet manage initState` + `pet edit initState` 三个时机几乎同帧触发。
  - 缓解：`_silentRefreshInFlight` flag 已 dedupe；最多一次网络请求。
- **风险 2**：用户已经在「编辑」页内按了"保存"，恰好后台 silentRefresh 把 pet 数据替换为新版本，导致用户保存的是"基于旧版本计算的 diff"。
  - 缓解：当前 `_save` 调的是 `PUT /pets/{id}`，后端按整字段覆盖（看 `pets.update_pet` 实现），不会因为前端拿到的是旧版本而合并冲突；最多是"另一个 owner 也在改"时后写胜出，本期接受。
- **风险 3**：`_petListResultEquals` 实现遗漏字段会导致永远 diff 不出来。
  - 缓解：实施时按 `pet.dart` 字段清单逐项加比对；测试用例覆盖 role / share_code_active / avatar_url 至少这 3 个。
- **回退**：把 `silentRefresh()` 在所有调用点替换为空方法（或者直接 git revert 这个 commit）即可，整体 UX 回到改动前的"必须手动下拉刷新"。

## 9. 估时

人 / agent ≈ 0.5 ~ 1 天（含双账号实机联调）。
