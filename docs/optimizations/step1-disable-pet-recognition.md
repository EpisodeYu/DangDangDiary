# Optimization Step 1 · 关闭上传时的宠物内容识别（保留代码）

> 状态：✅ 已落地（2026-05-23）。`enableClientPetRecognition = false`、`record_screen` 中两处 classifier 调用 + `_showRecognizingDialog` 已删除、上传 dialog 文案改为「正在处理上传」/「服务器正在保存」。后端 `ENABLE_SERVER_PET_RECOGNITION` 保持默认 false。后端 `pytest tests/api/test_photos.py` 12/12 通过；测试中带 `monkeypatch.setattr(settings, "ENABLE_SERVER_PET_RECOGNITION", True)` 的用例保持原行为，证明翻回 true 仍可正常工作。


## 1. 背景

当前上传照片有两层「是不是猫狗」识别：

- **前端**：`frontend/lib/services/pet_classifier.dart` 用 `tflite_flutter` 调用 `assets/models/pet_classifier.tflite` 做本地分类，阈值 0.08。在 `record_screen.dart` 的 `_pickFromGallery` / `_takePhoto` 中会同步阻塞 picker → "正在识别照片..." dialog → 失败弹 SnackBar "未识别到猫狗，请换一张图片试试吧！"。
- **后端**：`backend/app/services/image_recognition.py` 调用阿里云 `RecognizeScene`，在 `backend/app/api/v1/photos.py:_process_one` 内按 `settings.ENABLE_SERVER_PET_RECOGNITION` 切换是否阻断。当前线上默认关闭（`ENABLE_SERVER_PET_RECOGNITION: bool = False`）。

主要痛点：

1. 用户上传一张「合影 / 食盆 / 玩具 / 宠物用品 / 宠物医院发票」等强相关但不直接是猫狗的图片时，会被本地模型 reject，用户体验差。
2. 本地模型 ≈ 1.7 MB（`assets/models/pet_classifier.tflite`），并不便宜，但识别效果只能拦住明显不相关的图。
3. 后端 `RecognizeScene` 已经默认关，前端仍然在拦，造成「为什么我的照片被拒了」体验断裂。

## 2. 目标

- 完全不再因为「不是猫狗」拒绝任何照片：上传一律放行。
- **不删除代码与资源**——以便未来重新开启某种识别（例如服务器侧的更强模型 / 端云联合 / 内容合规检测）时可以最小成本恢复。
- 移除 UI 中所有与「正在识别照片...」「未识别到猫狗」相关的用户可见反馈。
- `record_screen.dart` 的添加照片路径不应再有任何同步阻塞的「识别」对话框；用户从相册选完图就应该立刻看到照片卡片。

## 3. 已决策

| 决策点 | 选定方案 | 理由 |
|--------|----------|------|
| 是否删除前端 TFLite 资源 / 依赖 / `pet_classifier.dart` | 否，保留 | 留作 future toggle |
| 是否删除后端 `image_recognition.py` 与 `ENABLE_SERVER_PET_RECOGNITION` | 否，保留 | 同上 |
| 前端识别开关的位置 | `AppConstants.enableClientPetRecognition = false` | 已存在，直接翻 flag |
| `record_screen.dart` 是否仍调用 `PetClassifier.instance.classify(...)` | 否，删除调用点 | classify 内部已有 early-return，但仍会产生「正在识别照片...」对话框 + 多余 await，删调用点才能让 UX 真的干净 |
| 上传提示文案 | 「选完照片将自动识别归属的宠物，最多 5 张」**不动** | 这里的"识别"指的是 Phase 2 Step 3 的「自动归属到某只宠物」，与猫狗内容识别无关 |

## 4. 修改清单

### 4.1 前端

| 文件 | 改动 |
|------|------|
| `frontend/lib/config/constants.dart` | `enableClientPetRecognition` → `false`；注释更新为"当前默认关闭，保留 flag 与代码以备未来恢复" |
| `frontend/lib/screens/record/record_screen.dart` | `_pickFromGallery` 中删除 `PetClassifier.instance.classify(...)` 调用和后续的 `rejected` 统计 / `_showSnack('未识别到猫狗...')`；`_takePhoto` 中删除 `PetClassifier.instance.classify(...)` 调用与拒绝逻辑；`_showRecognizingDialog()` 调用一并删除（已无意义） |
| `frontend/lib/services/pet_classifier.dart` | **保留不动**。它本身有 `if (!AppConstants.enableClientPetRecognition)` 的 early-return，flag 翻成 false 之后即使被调用也只会返回 `skipped=true`，不会真的加载 TFLite 模型 |
| `frontend/pubspec.yaml` | **保留不动**。`tflite_flutter`、`image` 依赖与 `assets/models/` 资源仍随包发布，包大小不变（约 +1.7 MB），但 startup 时不会触发 `Interpreter.fromAsset`，运行时开销为 0 |

### 4.2 后端

| 文件 | 改动 |
|------|------|
| `backend/app/config.py` | `ENABLE_SERVER_PET_RECOGNITION: bool = False`（已是 False，**保留不动**） |
| `backend/app/api/v1/photos.py` | **保留不动**。`if settings.ENABLE_SERVER_PET_RECOGNITION:` 分支自然不会进入 |
| `backend/app/services/image_recognition.py` | **保留不动** |
| `.env.example` / 部署文档 | 若有提到 `ENABLE_SERVER_PET_RECOGNITION=true` 的示例，改为 `=false` 并加注「Phase 2 Step 1 起默认关闭」 |

## 5. 详细步骤

### 5.1 `frontend/lib/config/constants.dart`

把 `enableClientPetRecognition` 字段的注释改写并把值翻为 `false`：

```dart
  /// 是否在上传前用本地 TFLite 模型校验图片中含有猫狗。
  ///
  /// 自 Optimization Step 1（2026-05）起默认关闭：用户经常上传
  /// 「宠物用品 / 合影 / 食盆 / 医院单据」等强相关但不直接是猫狗
  /// 的图片，本地模型阈值太严会误拒。后端的 `RecognizeScene`
  /// 同样默认关（见 `ENABLE_SERVER_PET_RECOGNITION`）。
  ///
  /// 保留 flag、保留 `pet_classifier.dart` 与 TFLite 资源，以便
  /// 未来若要恢复端侧识别（或换更强的模型）时直接翻回 true 即可。
  static const bool enableClientPetRecognition = false;
```

### 5.2 `frontend/lib/screens/record/record_screen.dart`

**`_pickFromGallery`**：移除 dialog + classify 调用 + rejected 统计：

```dart
Future<void> _pickFromGallery(int remaining) async {
  final List<XFile> picked;
  if (remaining == 1) {
    final one = await _picker.pickImage(source: ImageSource.gallery);
    picked = one == null ? const <XFile>[] : [one];
  } else {
    picked = await _picker.pickMultiImage(limit: remaining);
  }
  if (picked.isEmpty) return;

  final overflowed = picked.length > remaining;
  final toProcess = overflowed ? picked.take(remaining).toList() : picked;
  if (overflowed) {
    _showSnack('每次最多上传5张哦！');
  }

  // NOTE(opt-step1): 不再做猫狗识别，直接进入 EXIF 读取 + JPEG 压缩。
  // EXIF 必须在压缩前读，FlutterImageCompress 会丢失 metadata。
  final files = <File>[];
  final dates = <DateTime>[];
  final tokens = <String>[];
  for (final xfile in toProcess) {
    final exifDate = await ExifHelper.extractDate(File(xfile.path));
    final converted = await _ensureJpeg(xfile);
    final token = await _cachePending(converted);
    files.add(converted);
    tokens.add(token);
    dates.add(exifDate ?? DateTime.now());
  }

  if (!mounted) return;

  if (files.isEmpty) return;

  // ... 后续 `final editable = _editableCandidatePets;` 起的逻辑保持原样
}
```

**`_takePhoto`**：同样删除 dialog + classify：

```dart
Future<void> _takePhoto() async {
  final xfile = await _picker.pickImage(source: ImageSource.camera);
  if (xfile == null) return;
  if (_selectedFiles.length >= 5) return;

  final converted = await _ensureJpeg(xfile);
  final token = await _cachePending(converted);

  // ... 单 pet fast path + setState 保持原样
}
```

**`_showRecognizingDialog()`**：这个方法只剩 `_pickFromGallery` / `_takePhoto` 调用，删除调用后它本身可以删除；如果想保留留作日后复用也可以，但需要加 `// ignore: unused_element` 否则 lint 会报。**推荐直接删除**。

**`import '../../services/pet_classifier.dart';`**：删除该 import。注意 `import 'package:dio/dio.dart';` 等其他 import 不要误删，由 `_runClassifyAssignment` / `_submit` 内对 `DioException` 的捕获仍在用。

### 5.3 后端 / 部署文档

- 验证 `backend/app/config.py` 中 `ENABLE_SERVER_PET_RECOGNITION: bool = False` 仍是默认值。
- 若有任何已发布到生产的 `.env` 把它设为了 `true`，运维同步改回 `false`。
- `docs/step4-photo-record.md` 中如有「上传时会校验图片必须含猫狗」的描述，加一条 callout：
  > 自 Optimization Step 1 起，前后端默认都关闭了"必须包含猫狗"的识别。任何 JPG/PNG/WEBP 都可以上传。

### 5.4 跨步骤：Step 3 / Step 4 中的相关文案

- `_buildInitialState()` 中 "选完照片将自动识别归属的宠物，最多 5 张" 此处的"识别"指自动归属到某只宠物（Phase 2 Step 3），**不要改**。
- 上传 dialog `_showUploadDialog()` 中 `"共 $fileCount 张，正在检测宠物内容"` 这条文案是 server-processing 状态的描述（占位文案，跟猫狗识别无关），但为了避免歧义，**建议同步改成 "共 $fileCount 张，正在处理上传"**。

## 6. 数据 & API 兼容性

- 无数据库变更。
- 无 API 协议变更。
- 后端 `PHOTO_UPLOAD_FAILED.PET_NOT_DETECTED` 错误码不再被触发，但保留在响应模型中（前端 `record_screen` 的 failure 文案兜底仍可显示）。

## 7. 验证清单

后端：

1. `ENABLE_SERVER_PET_RECOGNITION=False` 下，向 `POST /api/v1/pets/{pet_id}/photos` 上传一张明显是风景的 JPG，期望 200 + success_count=1。
2. （回归）`ENABLE_SERVER_PET_RECOGNITION=True` 时，上传同一张风景仍会被拒（证明 flag 还能用，代码没坏）。

前端：

1. 安装后从相册选 1 张猫照 → 应该看到照片卡片立刻出现，无 "正在识别照片..." dialog。
2. 选 1 张非猫狗（例：合影、食盆、风景）→ 同样立刻看到照片卡片，**不再**有 "未识别到猫狗" SnackBar。
3. 拍照同样验证：拍一张无猫狗 → 直接进入卡片，无 dialog。
4. 多选 5 张混合内容 → 全部进入卡片，无任何识别相关阻塞。
5. （回归）每张卡片右上仍能切换归属的宠物（PetChipDropdown 不受影响）。
6. （回归）上传成功后时间轴出现新照片。

## 8. 风险与回退

- **风险 1**：用户上传不雅 / 违禁内容时，由于失去了猫狗白名单，第一道客户端拦截没了。
  - 缓解：本期不补 NSFW/违规内容检测；如需，后续单独立项接入阿里云内容安全（不是猫狗识别该解决的问题）。
- **风险 2**：保留死代码与资源导致包大小约多 1.7 MB。
  - 缓解：可接受。删除资源走 Step 1.1 followup 即可。
- **回退**：把 `enableClientPetRecognition = true` 翻回去 + 还原 `record_screen.dart` 的两处调用（git revert 该 commit 即可）。

## 9. 估时

人 / agent ≤ 1 小时。
