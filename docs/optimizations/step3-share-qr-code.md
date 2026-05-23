# Optimization Step 3 · 档案分享二维码（生成 / 保存 / 扫码加入）

> 状态：✅ 已落地（2026-05-23）。
> - 依赖新增：`qr_flutter ^4.1.0`、`mobile_scanner ^7.2.0`、`saver_gallery ^4.1.1`
> - 新增文件：`lib/services/share_link.dart`（`buildShareUrl` / `parseShareCode`）、`lib/widgets/share_qr_card.dart`、`lib/screens/profile/share/share_qr_preview_screen.dart`、`lib/screens/profile/share/share_scan_screen.dart`
> - `lib/config/constants.dart` 集中配置 `shareLinkBaseUrl` / `shareLinkHosts` / `shareCodePattern`
> - `pet_share_detail_screen.dart`：在「复制 / 重新生成」一行下方加「分享给好友 (QR 码)」按钮（过期时禁用）
> - `pet_edit_screen.dart`：原 `_buildRedeemButton` 改为弹底部 sheet（扫一扫 / 从相册选择二维码 / 手动输入分享码 / 取消）
> - `share_service.dart::shareErrorToMessage` 新增 `SHARE_QR_INVALID` 兜底文案
> - Android `AndroidManifest.xml` 增补 `CAMERA` 权限 + `<uses-feature android.hardware.camera required=false>`
> - iOS `Info.plist` 增补 `NSCameraUsageDescription` / `NSPhotoLibraryUsageDescription`；`NSPhotoLibraryAddUsageDescription` 文案改为通用版本（覆盖 step3 QR 卡片 + step5 原图）
>
> ⚠️ **关键人测项**（无法在本环境验证）：
> 1. `flutter pub get` 能正常拉到三个新依赖（`saver_gallery 4.1.1` 据 pub.dev 是最新版，`mobile_scanner 7.2.0` 是 3 个月前 release 的稳定版，应该都没问题）。
> 2. 实机扫一扫：摄像头权限弹窗 → 同意 → 看到 live preview → 对准 QR → pop 回 `_redeem` 成功。
> 3. 实机从相册选：相册权限弹窗 → 同意 → 选含 QR 的 PNG → 直接 `_redeem` 成功；选不含 QR 的风景图 → SnackBar "图片中没有识别到当当日记的分享码"。
> 4. 保存到相册：Android 13+ 静默成功；iOS 弹 Add-Only 权限 → 同意后看到相册有 `dangdang_share_<code>.png`。
> 5. 扫到第三方 QR（微信群名片 / Wi-Fi）→ SnackBar "这不是一张当当日记的分享码"，**不**误走 redeem。
>
> ⚠️ **占位域名**：`shareLinkBaseUrl = https://dangdangdiary.app/s/`。真正的域名买定后在 `constants.dart::shareLinkBaseUrl` 与 `shareLinkHosts` 一次性替换即可；老 QR 仍然能识别（因为 host 白名单保留旧域名）。

## 1. 背景

当前 `docs/phase2-step1-pet-share.md` 落地的档案分享流程：

- Owner 在「宠物档案管理 → 选某只宠物 → 档案分享」生成 8 位字母数字分享码（24 h 有效）。
- 接受者在「添加宠物档案」页面点「通过分享码添加档案」→ 弹 dialog 手动输入 8 位码 → 调 `POST /api/v1/pets/redeem`。

痛点：

1. Owner 没法直接把码"分享出去"，要复制 + 粘贴到 IM；老人 / 不熟手机的用户输入 8 位字符容易错。
2. 接受者只能手动输入，无 QR 扫码 / 相册图片识别。
3. 没有任何带品牌的分享物料，分享出去的码截图过于"裸"。

## 2. 目标

- **Owner 侧（生成）**：
  - 档案分享详情页（`pet_share_detail_screen.dart`）的「分享码卡片」下方新增「分享给好友」按钮。
  - 点击后弹出**可保存的 QR 卡片预览**：含 Logo + "DangDangDiary" 字样 + 宠物名 + 8 位码字符串 + 过期时间 + 一句邀请文案 + QR 本体。
  - 卡片预览中有「保存到相册」按钮，保存为 PNG（宽度约 720 px）。
  - 保存成功后给 SnackBar 提示。
- **接受者侧（识别）**：
  - 创建宠物档案页（`pet_edit_screen.dart` 新建模式）现有的「通过分享码添加档案」按钮改为弹底部 sheet，提供三个入口：
    1. 「扫一扫」→ 打开后置摄像头扫码
    2. 「从相册选择」→ 调系统相册 picker，对选中的图片做 QR 解析
    3. 「手动输入分享码」→ 走现有 8 位码输入 dialog
  - 任意入口拿到 8 位 code 后走现有 `shareService.redeemCode(code)`。
  - 二维码不属于当当日记时（无法解析为合法的 `https://dangdangdiary.app/s/<8 位 code>` URL），统一报错「这不是一张当当日记的分享码」。
- **协议**：QR 内容统一为 `https://dangdangdiary.app/s/<8 位 code>`。
  - 即使官网 / Web 落地页未来才上线，App 内扫码也只看 path 段，不依赖网络。
  - `dangdangdiary.app` 是占位域名，**实际域名以部署侧最终决定为准**，在 `AppConstants.shareLinkBaseUrl` 集中配置；若用户尚未购买正式域名，可暂用 `https://app.dangdangdiary.com/s/<code>` 等占位，但解析侧只要 host 命中白名单即可。

## 3. 已决策

| 决策点 | 选定方案 | 理由 |
|--------|----------|------|
| QR payload 协议 | HTTPS URL `https://dangdangdiary.app/s/<8 位 code>` | 易调试、未来可加 Web 落地页 |
| 域名 / host 白名单 | `AppConstants.shareLinkHosts = {'dangdangdiary.app', 'app.dangdangdiary.com'}` 双 host 兜底 | 防止域名最终调整时硬编码改不完 |
| 卡片附加信息 | Logo + DangDangDiary 字样 + 宠物名 + 8 位码 + 过期时间 + 邀请文案 | 已与产品对齐 |
| 邀请文案 | `扫码加入 <宠物名> 的档案，一起记录它的成长。` | 简短、可读 |
| 保存到相册依赖 | `saver_gallery: ^3.0.6+` | 跨平台稳定，活跃维护，与 Android 13 MediaStore + iOS Photos 都兼容 |
| 二维码生成依赖 | `qr_flutter: ^4.1.0` | 纯 Dart 渲染，无 native 依赖 |
| 摄像头扫码依赖 | `mobile_scanner: ^5.0.0+`（或 6.x 稳定版） | 最活跃，支持 iOS/Android，`analyzeImage(path)` 可直接解析相册图片中的 QR |
| 图片中 QR 解析方案 | `mobile_scanner` 的 `MobileScannerController.analyzeImage(filePath)` | 不需要再额外引入 `flutter_zxing` |
| 摄像头/相册权限 | 仅在按"扫一扫"或"从相册选择"时按需 request | 不在首次启动 / 登录时 request，遵守"刚需才申请" |
| 是否引入 deep link 处理 | 否，本期仅作为 QR 内容 | 未来若要支持点击 URL 直跳 App 再单独立项 |
| QR 解析失败提示 | `code = SHARE_QR_INVALID`，文案 "这不是一张当当日记的分享码" | 与现有 `shareErrorToMessage` 风格一致 |

## 4. 修改清单

### 4.1 新增 / 修改的前端文件

| 文件 | 改动 |
|------|------|
| `frontend/pubspec.yaml` | 新增依赖：`qr_flutter ^4.1.0`、`mobile_scanner ^5.0.0`（或最新稳定版）、`saver_gallery ^3.0.6` |
| `frontend/lib/config/constants.dart` | 新增 `shareLinkBaseUrl`（默认 `https://dangdangdiary.app/s/`）、`shareLinkHosts` 白名单、`shareCodePattern = RegExp(r'^[A-Z0-9]{8}$')` |
| `frontend/lib/services/share_link.dart` （新建） | `buildShareUrl(String code)`、`parseShareCode(String payload)` → `String?`（返回 8 位 code 或 null），统一负责"我们接受哪些字符串"的白名单逻辑 |
| `frontend/lib/widgets/share_qr_card.dart` （新建） | QR 卡片渲染 widget（用 `RepaintBoundary` 包裹便于截图），含 Logo + 文案 + QrImageView + 邀请语 |
| `frontend/lib/screens/profile/share/share_qr_preview_screen.dart` （新建） | 全屏预览页：含卡片预览 + "保存到相册" 按钮；保存逻辑用 `RenderRepaintBoundary.toImage()` + `saver_gallery` |
| `frontend/lib/screens/profile/share/share_scan_screen.dart` （新建） | 全屏扫码页：上方实时摄像头，下方"从相册选择"按钮 + 取消；扫到合法码立刻 pop 返回 code |
| `frontend/lib/screens/profile/share/pet_share_detail_screen.dart` | 在 `_buildActiveCode` 的 Row（复制 / 重新生成）下方再加一行「分享给好友 QR 码」按钮；点击后 push `share_qr_preview_screen` 并传 `code` / `petName` / `expiresAt` |
| `frontend/lib/screens/profile/pet_edit_screen.dart` | `_buildRedeemButton` + `_showRedeemDialog` 拆开：按钮改名为「通过分享码 / 二维码添加」，点击弹底部 sheet（扫一扫 / 从相册选择 / 手动输入分享码 / 取消）；扫一扫和相册识别都最终落到 `_redeem(code)` |
| `frontend/lib/services/share_service.dart` | 新增 `shareErrorToMessage` 对 `SHARE_QR_INVALID` 的本地映射（前端自造的错误码，后端不返回） |
| `frontend/android/app/src/main/AndroidManifest.xml` | 加 `<uses-permission android:name="android.permission.CAMERA"/>`；Android 13+ 相册不再需要存储权限，Android <13 需要 `READ_EXTERNAL_STORAGE`（保存图片到相册由 `saver_gallery` 走 MediaStore，无需 `WRITE_EXTERNAL_STORAGE`） |
| `frontend/ios/Runner/Info.plist` | 加 `NSCameraUsageDescription`（"扫描分享二维码"）、`NSPhotoLibraryAddUsageDescription`（"保存分享二维码到相册"）、`NSPhotoLibraryUsageDescription`（"从相册识别分享二维码"） |

### 4.2 后端

**无任何改动**。QR 内容只是 share code 的封装，扫码后调用现有 `POST /api/v1/pets/redeem`。
后端不返回宠物名 / 过期时间给非 owner，所以生成 QR 这一侧（owner 视角）必须从已经持有的 `pet.name` + `shareCode.expiresAt` 现场组装。

### 4.3 文档

| 文件 | 改动 |
|------|------|
| `docs/phase2-step1-pet-share.md` | 末尾追加 "Optimization Step 3 增强：QR 码 + 扫码加入" 章节，链回本文档 |
| `docs/optimizations/README.md` | 标 step3 完成 |

## 5. 详细步骤

### 5.1 依赖

`frontend/pubspec.yaml`：

```yaml
dependencies:
  # ... existing ...
  qr_flutter: ^4.1.0
  mobile_scanner: ^5.0.0
  saver_gallery: ^3.0.6
```

执行 `flutter pub get`。若 `mobile_scanner` 新版要求 minSdkVersion 21+，`frontend/android/app/build.gradle` 同步检查（当前项目已经 21+，应无需改）。

### 5.2 `lib/config/constants.dart`

```dart
class AppConstants {
  // ... existing ...

  /// 二维码 payload 使用的 URL 前缀。生成时按 `<prefix><8 位 code>` 拼接，
  /// 解析时按 `shareLinkHosts` 白名单 + path = `/s/<8 位 code>` 校验。
  ///
  /// `dangdangdiary.app` 是占位主域名，最终域名以部署侧决定为准；
  /// 这里集中配置便于一次性替换。
  static const String shareLinkBaseUrl = 'https://dangdangdiary.app/s/';

  /// 允许接收的二维码 host 白名单（前端校验）。
  static const Set<String> shareLinkHosts = {
    'dangdangdiary.app',
    'app.dangdangdiary.com',
  };

  /// 分享码字符集（与后端 `generate_invite_code` 保持一致）。
  static final RegExp shareCodePattern = RegExp(r'^[A-Z0-9]{8}$');
}
```

### 5.3 `lib/services/share_link.dart`（新建）

```dart
import '../config/constants.dart';

/// Build the QR payload URL for an 8-character share code.
String buildShareUrl(String code) => '${AppConstants.shareLinkBaseUrl}$code';

/// Extract a valid 8-character share code from an arbitrary scanned payload.
/// Returns null when the payload is not one of:
///   - https://<whitelisted host>/s/<8 alphanum>
///   - the 8 alphanum code itself (manual entry)
String? parseShareCode(String payload) {
  final trimmed = payload.trim();
  if (trimmed.isEmpty) return null;

  // Direct 8-char alphanumeric (manual input fallback).
  final upper = trimmed.toUpperCase();
  if (AppConstants.shareCodePattern.hasMatch(upper)) return upper;

  // URL form.
  final uri = Uri.tryParse(trimmed);
  if (uri == null) return null;
  if (uri.scheme != 'https' && uri.scheme != 'http') return null;
  if (!AppConstants.shareLinkHosts.contains(uri.host.toLowerCase())) return null;
  if (uri.pathSegments.length != 2) return null;
  if (uri.pathSegments[0] != 's') return null;
  final code = uri.pathSegments[1].toUpperCase();
  if (!AppConstants.shareCodePattern.hasMatch(code)) return null;
  return code;
}
```

### 5.4 `lib/widgets/share_qr_card.dart`（新建）

QR 卡片是一个固定逻辑尺寸的 widget（建议 360 × 540 dp 卡片，最终保存时让 `toImage` pixelRatio = 2 ~ 3 得到 720 × 1080 px PNG）。结构如下：

```
┌────────────────────────────────────────┐
│  [Logo 48dp]   DangDangDiary           │
│                当当日记                  │
├────────────────────────────────────────┤
│                                        │
│  扫码加入 <宠物名> 的档案，               │
│  一起记录它的成长。                       │
│                                        │
│   ┌──────────────────────┐             │
│   │                      │             │
│   │       QR 240dp       │             │
│   │                      │             │
│   └──────────────────────┘             │
│                                        │
│  分享码：A B C D 1 2 3 4                 │
│  有效期至：2026-05-23 23:59             │
│                                        │
└────────────────────────────────────────┘
```

关键代码骨架：

```dart
class ShareQrCard extends StatelessWidget {
  final String code;
  final String petName;
  final DateTime expiresAt;

  const ShareQrCard({
    super.key,
    required this.code,
    required this.petName,
    required this.expiresAt,
  });

  @override
  Widget build(BuildContext context) {
    final url = buildShareUrl(code);
    return Container(
      width: 360,
      // 不用固定 height，让内部自然撑开；预览页用 FittedBox 即可。
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [BoxShadow(color: Colors.black12, blurRadius: 10)],
      ),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SvgPicture.asset('assets/brand/logo.svg', width: 40, height: 40),
              const SizedBox(width: 10),
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('DangDangDiary',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  Text('当当日记',
                      style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 20),
          Text(
            '扫码加入 $petName 的档案，\n一起记录它的成长。',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 240,
              gapless: false,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              // 可选：把 logo embed 进 QR 中心（QR_ECL_H 才稳定，复杂度自行权衡）
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '分享码  ${_spaced(code)}',
            style: const TextStyle(
              fontSize: 18,
              letterSpacing: 4,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '有效期至：${_formatExpiry(expiresAt)}',
            style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  String _spaced(String s) => s.split('').join(' ');

  String _formatExpiry(DateTime d) {
    final local = d.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}';
  }
}
```

### 5.5 `lib/screens/profile/share/share_qr_preview_screen.dart`（新建）

```dart
class ShareQrPreviewScreen extends StatefulWidget {
  final String code;
  final String petName;
  final DateTime expiresAt;

  const ShareQrPreviewScreen({...});

  @override
  State<ShareQrPreviewScreen> createState() => _ShareQrPreviewScreenState();
}

class _ShareQrPreviewScreenState extends State<ShareQrPreviewScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final boundary = _boundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ImageByteFormat.png);
      if (byteData == null) throw '截图失败';
      final pngBytes = byteData.buffer.asUint8List();

      // saver_gallery API: see https://pub.dev/packages/saver_gallery
      final result = await SaverGallery.saveImage(
        pngBytes,
        fileName: 'dangdang_share_${widget.code}.png',
        skipIfExists: false,
        androidRelativePath: 'Pictures/DangDangDiary',
      );
      if (!mounted) return;
      if (result.isSuccess) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存到相册')),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：${result.errorMessage ?? "未知错误"}')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('分享给好友')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Center(
              child: RepaintBoundary(
                key: _boundaryKey,
                child: ShareQrCard(
                  code: widget.code,
                  petName: widget.petName,
                  expiresAt: widget.expiresAt,
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_alt),
                label: Text(_saving ? '保存中...' : '保存到相册'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '保存后可在相册中分享给好友，对方扫一扫即可加入档案。',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
```

### 5.6 `lib/screens/profile/share/share_scan_screen.dart`（新建）

```dart
class ShareScanScreen extends StatefulWidget {
  const ShareScanScreen({super.key});

  @override
  State<ShareScanScreen> createState() => _ShareScanScreenState();
}

class _ShareScanScreenState extends State<ShareScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final code = parseShareCode(raw);
      if (code != null) {
        _handled = true;
        Navigator.of(context).pop(code);
        return;
      } else {
        // 命中了一张 QR 但不是当当日记的——给一次性反馈，不退出。
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('这不是一张当当日记的分享码'),
            duration: Duration(seconds: 2),
          ),
        );
        // 让用户继续对焦下一个；用 hot-cool delay 避免 spam
        _handled = true;
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) _handled = false;
        });
        return;
      }
    }
  }

  Future<void> _pickFromGallery() async {
    final picker = ImagePicker();
    final xfile = await picker.pickImage(source: ImageSource.gallery);
    if (xfile == null || !mounted) return;
    final result = await _controller.analyzeImage(xfile.path);
    if (!mounted) return;
    if (result == null || result.barcodes.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('图片中没有识别到二维码')),
      );
      return;
    }
    for (final barcode in result.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null) continue;
      final code = parseShareCode(raw);
      if (code != null) {
        Navigator.of(context).pop(code);
        return;
      }
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('这不是一张当当日记的分享码')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描分享二维码')),
      body: Column(
        children: [
          Expanded(
            child: MobileScanner(
              controller: _controller,
              onDetect: _onDetect,
              fit: BoxFit.cover,
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickFromGallery,
                      icon: const Icon(Icons.photo_library_outlined),
                      label: const Text('从相册选择'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close),
                      label: const Text('取消'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
```

> `_onDetect` 的"识别到非当当日记 QR 后冷却 2 秒"是为了在用户对着任意 QR（例如微信群名片）扫的时候避免 SnackBar 抖动。

### 5.7 `lib/screens/profile/share/pet_share_detail_screen.dart`

在 `_buildActiveCode` 的 Row（"复制" / "重新生成"）下方新增一行按钮：

```dart
// 现有 Row 之后
const SizedBox(height: 12),
SizedBox(
  width: double.infinity,
  child: OutlinedButton.icon(
    onPressed: expired ? null : () => _openQrPreview(context, code),
    icon: const Icon(Icons.qr_code_2),
    label: const Text('分享给好友 (QR 码)'),
  ),
),
```

实现：

```dart
void _openQrPreview(BuildContext context, ShareCode code) {
  final petListAsync = ref.read(petListProvider);
  final pet = petListAsync.valueOrNull?.pets
      .where((p) => p.id == widget.petId)
      .firstOrNull;
  final petName = pet?.name ?? '我的宠物';
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => ShareQrPreviewScreen(
        code: code.code,
        petName: petName,
        expiresAt: code.expiresAt,
      ),
    ),
  );
}
```

### 5.8 `lib/screens/profile/pet_edit_screen.dart`

修改 `_buildRedeemButton` 的 onPressed：

```dart
Widget _buildRedeemButton() {
  return SizedBox(
    height: 48,
    child: OutlinedButton.icon(
      onPressed: _isLoading ? null : _showRedeemEntrySheet,
      icon: const Icon(Icons.qr_code_2),
      label: const Text('通过分享码 / 二维码添加'),
      ...
    ),
  );
}
```

新增方法：

```dart
Future<void> _showRedeemEntrySheet() async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.qr_code_scanner),
            title: const Text('扫一扫'),
            onTap: () => Navigator.pop(ctx, 'scan'),
          ),
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('从相册选择二维码'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.dialpad),
            title: const Text('手动输入分享码'),
            onTap: () => Navigator.pop(ctx, 'manual'),
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

  switch (choice) {
    case 'scan':
      final code = await Navigator.of(context).push<String>(
        MaterialPageRoute(builder: (_) => const ShareScanScreen()),
      );
      if (code != null) await _redeem(code);
      break;
    case 'gallery':
      // 复用 ShareScanScreen 的相册识别逻辑：可以直接 push ShareScanScreen
      // 然后让它自动触发 `_pickFromGallery`；或者抽一个无 UI 的 helper。
      // 推荐：抽 helper 函数 `pickShareCodeFromGallery(BuildContext)`
      // 返回 String? code。
      final code = await pickShareCodeFromGallery(context);
      if (code != null) await _redeem(code);
      break;
    case 'manual':
      await _showRedeemDialog(); // 现有逻辑
      break;
  }
}
```

抽出的 helper（建议放在 `lib/services/share_link.dart` 同目录，新建 `lib/utils/share_qr_picker.dart`）：

```dart
Future<String?> pickShareCodeFromGallery(BuildContext context) async {
  final picker = ImagePicker();
  final xfile = await picker.pickImage(source: ImageSource.gallery);
  if (xfile == null) return null;
  final controller = MobileScannerController();
  try {
    final result = await controller.analyzeImage(xfile.path);
    if (result == null || result.barcodes.isEmpty) {
      _toast(context, '图片中没有识别到二维码');
      return null;
    }
    for (final b in result.barcodes) {
      final raw = b.rawValue;
      if (raw == null) continue;
      final code = parseShareCode(raw);
      if (code != null) return code;
    }
    _toast(context, '这不是一张当当日记的分享码');
    return null;
  } finally {
    await controller.dispose();
  }
}

void _toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
}
```

### 5.9 `lib/services/share_service.dart`

`shareErrorToMessage` 中追加：

```dart
case 'SHARE_QR_INVALID':
  return '这不是一张当当日记的分享码';
```

（虽然后端不会返回这个 code，但前端在抛 `DioException` 之外的 helper 路径上也可以走同一 helper。简单点：直接在 share_scan / picker 里用字面量 SnackBar 即可，无需经过 `shareErrorToMessage`。两种风格选一种，文档不强制。）

### 5.10 Android 权限

`frontend/android/app/src/main/AndroidManifest.xml`：

```xml
<uses-permission android:name="android.permission.CAMERA"/>
<uses-feature android:name="android.hardware.camera" android:required="false"/>
<!-- Android 13- 才需要；13+ 用 photo picker，无需声明 -->
<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
    android:maxSdkVersion="32"/>
```

> 保存到相册：`saver_gallery` 默认走 MediaStore（Android Q+），不需要 `WRITE_EXTERNAL_STORAGE`。

### 5.11 iOS 权限

`frontend/ios/Runner/Info.plist`：

```xml
<key>NSCameraUsageDescription</key>
<string>用于扫描宠物档案分享二维码</string>
<key>NSPhotoLibraryAddUsageDescription</key>
<string>用于将宠物档案分享二维码保存到相册</string>
<key>NSPhotoLibraryUsageDescription</key>
<string>用于从相册识别宠物档案分享二维码</string>
```

## 6. UX 细节

- QR 预览页 `SingleChildScrollView` 包裹，竖屏短设备能滚到底部"保存"按钮。
- 保存进行中按钮置灰 + 显示 "保存中..."；完成后 SnackBar `已保存到相册`。
- 扫码页打开时若摄像头权限被拒绝，`mobile_scanner` 默认会触发 onError，UI 上加一个"权限被拒，请到系统设置开启"提示并提供「去设置」按钮（用 `permission_handler` 的 `openAppSettings()`，依赖项目已有的 `permission_handler`）。
- 扫码识别到非合法 QR 时 SnackBar 提示 "这不是一张当当日记的分享码"，**不退出**扫码页，让用户继续扫。
- 相册选择的图片：如果一张图片里有多个 QR，按 `barcodes` 顺序遍历，找到第一个合法的即返回；如果都不合法，SnackBar 提示同上。
- QR 卡片背景使用白色，QR 本体周围留白 `>= 16 px`（避免被相机识别失败）。
- QR 中心**不嵌入 Logo**（嵌入 Logo 需要 ECL=H，会让 QR 模块更密；考虑到我们的 payload 长度较短 + 兼容性，先不嵌）。Logo 放在卡片头部即可。

## 7. 数据 & API 兼容性

- 无后端协议变更。
- QR payload 是新引入的，不会与现有分享码字符串冲突（现有 dialog 仍只看 8 位字母数字）。
- 旧客户端依然能"复制 / 重新生成"，看不到"分享给好友 QR 码"按钮，但功能不破坏。

## 8. 验证清单

Owner 侧：

1. 进入「档案分享」页，看到「分享给好友 (QR 码)」按钮。已过期时按钮置灰。
2. 点击进入预览页：卡片显示 Logo + DangDangDiary + 宠物名 + 8 位码（按 4-4 排列、字号醒目）+ 过期时间 + 邀请文案 + 居中 QR。
3. 「保存到相册」首次会触发权限请求；同意后 SnackBar 提示「已保存到相册」。打开系统相册可看到 `Pictures/DangDangDiary/dangdang_share_<code>.png`。
4. 再次保存：直接成功，无重复权限请求。

接受者侧：

1. 在「创建宠物档案」点「通过分享码 / 二维码添加」→ 弹底部 sheet 三选一。
2. 「扫一扫」首次触发相机权限；扫描第一步保存的 QR → 直接成功 redeem，进入 pet list 看到新档案。
3. 「扫一扫」对着任意非当当日记 QR（如微信群名片）→ SnackBar 提示「这不是一张当当日记的分享码」，**不**误走 redeem。
4. 「从相册选择」→ 选第一步保存的 PNG → 成功 redeem。
5. 「从相册选择」→ 选一张不含 QR 的风景照 → SnackBar「图片中没有识别到二维码」。
6. 「从相册选择」→ 选一张含其他 QR（如微信） → SnackBar「这不是一张当当日记的分享码」。
7. 「手动输入分享码」→ 现有 8 位输入 dialog → 成功 redeem。

回归：

1. 已过期的分享码生成 QR 后扫描，后端返回 `SHARE_CODE_EXPIRED`，前端 `shareErrorToMessage` 已能映射到「分享码已过期」。
2. 自己扫自己生成的 QR → `SHARE_CODE_SELF_REDEEM`。

## 9. 风险与回退

- **风险 1**：mobile_scanner 版本升级偶有 breaking change（API 接收 `BarcodeCapture` vs `Barcode`）。
  - 缓解：pubspec 钉到一个具体 minor 版本，跨版本升级时先在隔离分支验证。
- **风险 2**：iOS 13/14 老机型上 `mobile_scanner` 初始化偶尔较慢（首次约 800 ms）。
  - 缓解：扫码页有 placeholder loading；本期不做特别优化。
- **风险 3**：用户从微信收藏的图片识别 QR 时，部分微信图压缩很重导致 QR 损坏。
  - 缓解：友好提示用户保存原图再识别；本期不做云端兜底识别。
- **回退**：把入口按钮改回直接打开输入 dialog，移除底部 sheet；QR 预览页改为不可达。新建文件 + 新依赖均独立提交，便于 git revert。

## 10. 估时

人 / agent ≈ 1.5 ~ 2 天（含 iOS / Android 权限实机联调）。
