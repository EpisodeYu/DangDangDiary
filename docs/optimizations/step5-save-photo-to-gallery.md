# Optimization Step 5 · 长按保存原图到本地相册

> 状态：✅ 已落地（2026-05-23）。`saver_gallery: ^4.1.1` 已加入 pubspec；新建 `lib/services/photo_saver.dart`；时间轴 + 大图查看器两处长按 sheet 均与「删除」平级新增「保存到相册」项；Android Manifest 增补 `WRITE_EXTERNAL_STORAGE`（maxSdk=28）/`READ_EXTERNAL_STORAGE`（maxSdk=32）/`READ_MEDIA_IMAGES`；iOS Info.plist 增补 `NSPhotoLibraryAddUsageDescription`。
>
> ⚠️ 注意：由于本仓库未安装 Flutter SDK，**未跑 `flutter analyze` / `flutter test`**。结构、import、API 签名均按 saver_gallery 4.1.1 官方文档对齐（`saveImage(bytes, name:, androidRelativePath:, skipIfExists:)` → `SaveResult{isSuccess, errorMessage}`）。`permission_handler` 已在依赖里，使用 `Permission.photosAddOnly`（iOS）/ `Permission.storage`（Android 旧版兜底）。**实机权限弹窗 + 实际保存路径需要人测**。

## 1. 背景

当前长按照片的入口有两处，都弹出一个 bottom sheet：

- **时间轴 calendar 模式**（`timeline_screen.dart:_showPhotoActionSheet`）：详细信息 / 多选 / 删除 / 取消。
- **大图查看器**（`photo_viewer_screen.dart:_onLongPress`）：详细信息 / 删除 / 取消。

产品诉求：在两处 sheet 内**与删除按钮平级**新增「保存到相册」，把当前照片的**原图**保存到系统相册。

## 2. 目标

- 时间轴长按 sheet 与大图查看器长按 sheet 都新增「保存到相册」项，置于「详细信息」之后、「删除」之前。
- 保存的是**原图**（非缩略图，非压缩件），用 `OriginalPhotoCache.fetchOriginal(photoId)` 拿到已缓存或新下载的 JPEG 文件。
- 保存中按钮 / SnackBar 给出 loading 提示；保存成功显示「已保存到相册」；失败给出可读错误。
- 权限按需 request；Android 13+ 走 MediaStore 不需要 WRITE 权限，iOS 需要 `NSPhotoLibraryAddUsageDescription`。
- **本期只支持单张**保存（与"多选 → 批量删除"对齐，不在多选 bottom bar 加批量保存）。

## 3. 已决策

| 决策点 | 选定方案 | 理由 |
|--------|----------|------|
| 保存范围 | 单张（时间轴 sheet + 大图 sheet） | 多选场景操作面板已经有删除，保存批量加上去过载且少有用 |
| 第三方依赖 | `saver_gallery: ^3.0.6+`（与 Step 3 共用） | 活跃维护，跨平台稳定 |
| 拿原图的方式 | 复用 `OriginalPhotoCache.instance.fetchOriginal(photoId)` | 已有完整的本地缓存 + 预签名 URL 下载逻辑，无需重复造轮子 |
| 保存到系统相册的位置 | `Pictures/DangDangDiary/` (Android) / 系统相册"最近"（iOS） | 同 Step 3 QR 卡片，统一收纳 |
| 文件名 | `dangdang_photo_<photoId>_<takenAt>.jpg` | 重复保存自动数字后缀（saver_gallery 行为） |
| 错误处理 | 失败 SnackBar 区分"网络下载失败 / 权限被拒 / IO 失败" | 体验细节 |

## 4. 修改清单

### 4.1 前端

| 文件 | 改动 |
|------|------|
| `frontend/pubspec.yaml` | `saver_gallery: ^3.0.6`（若 Step 3 已加，**复用同一行**） |
| `frontend/lib/services/photo_saver.dart` （新建） | 封装 `Future<SaveResult> savePhotoToGallery(int photoId, {DateTime? takenAt})`；内部调 `OriginalPhotoCache.fetchOriginal` + `SaverGallery.saveFile` |
| `frontend/lib/screens/timeline/timeline_screen.dart` | `_showPhotoActionSheet` 加 `save` 项；`_handlePhotoSheetAction` 加 `case 'save'`；新增 `_savePhotoToGallery(TimelinePhoto)` |
| `frontend/lib/screens/timeline/photo_viewer_screen.dart` | `_onLongPress` 中的 sheet 加 `save` 项；分支处理同上 |
| `frontend/android/app/src/main/AndroidManifest.xml` | （若 Step 3 已加 CAMERA / READ_EXTERNAL_STORAGE）无需新增；`saver_gallery` 在 Android 13+ 默认走 MediaStore，**不需要 WRITE_EXTERNAL_STORAGE** |
| `frontend/ios/Runner/Info.plist` | 加 `NSPhotoLibraryAddUsageDescription`（"保存原图到相册"）；若 Step 3 已加则文案合并：`"保存分享二维码或原图到相册"` |

### 4.2 后端

**无改动**。

## 5. 详细步骤

### 5.1 依赖

如果 Step 3 已经加了 `saver_gallery`，跳过；否则在 `pubspec.yaml`：

```yaml
dependencies:
  # ...
  saver_gallery: ^3.0.6
```

### 5.2 `lib/services/photo_saver.dart`（新建）

```dart
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:saver_gallery/saver_gallery.dart';

import 'original_photo_cache.dart';

/// Result of `savePhotoToGallery`.
class PhotoSaveResult {
  final bool success;
  final String? errorMessage;

  const PhotoSaveResult.success() : success = true, errorMessage = null;
  const PhotoSaveResult.failure(this.errorMessage) : success = false;
}

/// Save the original (full-resolution) bytes of [photoId] to the system
/// gallery. Reuses [OriginalPhotoCache] so already-cached photos save
/// without a fresh download.
///
/// On Android 13+, uses MediaStore (no extra permission required).
/// On Android <13, `saver_gallery` requests `WRITE_EXTERNAL_STORAGE`
/// implicitly; if the user denies, returns a failure result.
/// On iOS, requires `NSPhotoLibraryAddUsageDescription` in Info.plist.
Future<PhotoSaveResult> savePhotoToGallery(
  int photoId, {
  DateTime? takenAt,
}) async {
  try {
    final file = await OriginalPhotoCache.instance.fetchOriginal(photoId);
    if (!await file.exists()) {
      return const PhotoSaveResult.failure('文件已被清理，请稍后重试');
    }
    final bytes = await file.readAsBytes();
    final filename = _buildFilename(photoId, takenAt);
    final result = await SaverGallery.saveImage(
      bytes,
      fileName: filename,
      androidRelativePath: 'Pictures/DangDangDiary',
      skipIfExists: false,
    );
    if (result.isSuccess) return const PhotoSaveResult.success();
    return PhotoSaveResult.failure(
      result.errorMessage?.isNotEmpty == true
          ? result.errorMessage!
          : '保存失败，请检查相册权限',
    );
  } on FileSystemException catch (e) {
    debugPrint('[photoSaver] FS error: $e');
    return PhotoSaveResult.failure('读取原图失败');
  } catch (e, st) {
    debugPrint('[photoSaver] save failed: $e\n$st');
    final msg = e.toString().toLowerCase();
    if (msg.contains('network') || msg.contains('timeout')) {
      return const PhotoSaveResult.failure('网络异常，请稍后重试');
    }
    return const PhotoSaveResult.failure('保存失败，请稍后重试');
  }
}

String _buildFilename(int photoId, DateTime? takenAt) {
  final ts = (takenAt ?? DateTime.now()).toLocal();
  final stamp = '${ts.year}${_pad(ts.month)}${_pad(ts.day)}_'
      '${_pad(ts.hour)}${_pad(ts.minute)}${_pad(ts.second)}';
  return 'dangdang_photo_${photoId}_$stamp.jpg';
}

String _pad(int v) => v.toString().padLeft(2, '0');
```

> 注：`SaverGallery` 当前对 iOS 的 `saveImage` API 接受 Uint8List + fileName，自动推断为 JPEG/PNG（按 magic bytes）；我们的原图始终是 JPEG，所以文件名带 `.jpg` 即可。若 `saver_gallery` 新版 API 签名变化（比如把 `androidRelativePath` 改成 `relativePath`），按 pub.dev 文档调整。

### 5.3 `lib/screens/timeline/timeline_screen.dart`

`_showPhotoActionSheet` 加 `save` 项：

```dart
Future<String?> _showPhotoActionSheet({required bool allowMultiSelect}) {
  return showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('详细信息'),
            onTap: () => Navigator.pop(ctx, 'info'),
          ),
          if (allowMultiSelect)
            ListTile(
              leading: const Icon(Icons.check_box_outlined),
              title: const Text('多选'),
              onTap: () => Navigator.pop(ctx, 'multi'),
            ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('保存到相册'),
            onTap: () => Navigator.pop(ctx, 'save'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: AppTheme.errorColor),
            title: const Text('删除', style: TextStyle(color: AppTheme.errorColor)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('取消'),
            onTap: () => Navigator.pop(ctx),
          ),
        ],
      ),
    ),
  );
}
```

`_handlePhotoSheetAction` 新增 `case 'save'`：

```dart
Future<void> _handlePhotoSheetAction(
  TimelinePhoto photo,
  String? action,
) async {
  switch (action) {
    case 'info':
      await showPhotoInfoDialog(context, photo);
      break;
    case 'multi':
      _enterSelection(photo.id);
      break;
    case 'save':
      await _savePhotoToGallery(photo);
      break;
    case 'delete':
      final confirmed = await _confirmDelete(1);
      if (!mounted || confirmed != true) return;
      await _deleteSinglePhoto(photo.id);
      break;
  }
}
```

新增 `_savePhotoToGallery`：

```dart
Future<void> _savePhotoToGallery(TimelinePhoto photo) async {
  _showSnack('正在保存...');
  final result = await savePhotoToGallery(photo.id, takenAt: photo.takenAt);
  if (!mounted) return;
  if (result.success) {
    _showSnack('已保存到相册');
  } else {
    _showSnack(result.errorMessage ?? '保存失败');
  }
}
```

> 进度提示用 SnackBar 即可。如果原图 cache miss + 大文件下载耗时较长（> 2 s），可以改为短暂 dialog；先按 SnackBar 简洁版做，按用户反馈再调。

### 5.4 `lib/screens/timeline/photo_viewer_screen.dart`

`_onLongPress` 中的 sheet 加 `save` 项；并把 `_savePhotoToGallery` 适配：

```dart
Future<void> _onLongPress(int photoId) async {
  final photo = ref.read(timelineProvider).photoMap[photoId];
  if (photo == null) return;
  final action = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('详细信息'),
            onTap: () => Navigator.pop(ctx, 'info'),
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('保存到相册'),
            onTap: () => Navigator.pop(ctx, 'save'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: AppTheme.errorColor),
            title: const Text('删除', style: TextStyle(color: AppTheme.errorColor)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
          ListTile(
            leading: const Icon(Icons.close),
            title: const Text('取消'),
            onTap: () => Navigator.pop(ctx),
          ),
        ],
      ),
    ),
  );
  if (!mounted) return;
  switch (action) {
    case 'info':
      await showPhotoInfoDialog(context, photo);
      break;
    case 'save':
      _showSnack('正在保存...');
      final result = await savePhotoToGallery(photo.id, takenAt: photo.takenAt);
      if (!mounted) return;
      _showSnack(result.success ? '已保存到相册' : (result.errorMessage ?? '保存失败'));
      break;
    case 'delete':
      final confirmed = await _confirmDelete();
      if (!mounted || confirmed != true) return;
      await _deletePhoto(photoId);
      break;
  }
}
```

注意：`photo_viewer_screen.dart` 中现有的 `_showSnack` 已存在；`photo` 变量从 `state.photoMap[currentId]` 取到，含 `takenAt`，直接复用。

### 5.5 iOS `Info.plist`

如果 Step 3 已加 `NSPhotoLibraryAddUsageDescription`，文案改成更通用：

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>用于保存宠物原图或分享二维码到相册</string>
```

如果 Step 3 未做，独立加：

```xml
<key>NSPhotoLibraryAddUsageDescription</key>
<string>用于保存宠物原图到相册</string>
```

### 5.6 Android `AndroidManifest.xml`

- Android 13+：默认无需任何额外权限（`saver_gallery` 走 MediaStore Public API）。
- Android <13：`saver_gallery` 在内部按需触发 `WRITE_EXTERNAL_STORAGE` request；为了 manifest 通过 Play Store 审核，**不主动**声明 WRITE 权限 —— 让 `saver_gallery` 通过自身的 native shim 处理，本期不为旧版本优化（项目 minSdk 已 ≥ 21；多数活跃设备 ≥ Android 11）。

如果出现旧设备保存失败的反馈，再单独加：

```xml
<uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE"
    android:maxSdkVersion="28"/>
```

## 6. 数据 & API 兼容性

- 无后端协议变更。
- 无任何状态 / 缓存语义改动；`OriginalPhotoCache` 只是被新调用方多用一次。

## 7. 验证清单

时间轴长按：

1. 任一照片长按 → bottom sheet 内出现「保存到相册」（在删除之前，与删除平级）。
2. 点击 → SnackBar 立刻显示「正在保存...」；保存完成 SnackBar 切换为「已保存到相册」。
3. 在系统相册的 `DangDangDiary` 文件夹（或最近）能看到刚保存的图片。打开看是**原图**（非缩略图模糊版）。
4. 同一张再保存一次：相册里出现第二张（文件名自动后缀）。
5. 该照片本地没缓存的情况下保存（先清缓存或换一张刚加载的）：内部触发 download，SnackBar 「正在保存...」期间不阻塞 UI，完成后切换为成功提示。

大图查看器长按：

1. 任一照片在大图查看器内长按 → sheet 内出现「保存到相册」。
2. 行为与时间轴一致。

权限：

1. iOS 首次保存 → 系统弹相册写入权限请求；同意后保存成功。
2. iOS 拒绝权限 → SnackBar 显示「保存失败，请检查相册权限」之类（来自 saver_gallery 的 errorMessage）。
3. Android 13+ → 不触发任何权限请求。
4. Android 12 及以下 → 首次保存触发 WRITE 权限；同意后保存成功。

回归：

1. 时间轴现有「详细信息 / 多选 / 删除 / 取消」功能不受影响。
2. 大图查看器现有「详细信息 / 删除 / 取消」功能不受影响。
3. 多选模式下底部 bar 仍只有「删除 (N)」，**不增加批量保存**。

## 8. 风险与回退

- **风险 1**：大文件原图保存时间长（5 MB 文件保存 ≈ 500 ms），用户重复点击可能触发多次保存。
  - 缓解：第一版接受重复保存；若反馈强烈，按钮加 in-flight 状态 dedup。
- **风险 2**：保存动作本身是写系统外部存储，无法保证 100% 成功（设备空间不足 / 系统相册被禁用等）。
  - 缓解：所有失败路径都返回结构化 `PhotoSaveResult`，UI 给出可读 SnackBar，不崩溃。
- **风险 3**：`OriginalPhotoCache.fetchOriginal` 失败（网络断 / 后端 503）时，用户拿不到原图。
  - 缓解：错误信息会被 photo_saver.dart catch 后归类为「网络异常」，SnackBar 提示。
- **回退**：删除 sheet 的两个 `ListTile`（时间轴 + 大图）即可；photo_saver.dart 可保留为 dead code，无副作用。

## 9. 估时

人 / agent ≈ 0.5 天（含两端实机权限验证）。
