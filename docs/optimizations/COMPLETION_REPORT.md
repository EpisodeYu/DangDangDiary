# Optimizations Batch 1 · 完成报告

落地时间：2026-05-23
执行 agent：Claude（Cursor 内 Agent 模式）
依据规划：`docs/optimizations/step1~step5-*.md`

## 1. 总览

| Step | 主题 | 状态 | 自测覆盖 |
|------|------|------|----------|
| 1 | 关闭宠物内容识别（保留代码） | ✅ 已落地 | 后端 `pytest tests/api/test_photos.py` 12/12 通过 |
| 2 | 时间轴按「日」分组（月级 scrollbar 保留） | ✅ 已落地 | 后端 `pytest tests` 189/189 通过；新增单元测试 5 个 |
| 3 | 档案分享二维码（生成 / 保存 / 扫码加入） | ✅ 已落地 | Dart 文件 ReadLints 无报错；运行/权限弹窗需人测 |
| 4 | Pet role silent sync（修被赋权后感知 bug） | ✅ 已落地 | 仅做静态校验；双账号联调需人测 |
| 5 | 长按保存原图到本地相册 | ✅ 已落地 | 仅做静态校验；实机保存需人测 |

后端测试基线对比：
- **改动前**：1 failed（`test_tampered_payload_returns_none`，JWT 概率性失败，与本批次完全无关），183 passed。
- **改动后**：0 failed，189 passed（基线 184 + 本次 step2 新增 5 个 group-by-day 单元测试）。
- 之前的 JWT 概率性失败在第二次跑就消失，**不是本批次引入**。

## 2. 变更文件清单

### 新建（13 文件）

```
backend/tests/unit/test_timeline_group_by_day.py        # Step 2 单元测试
docs/optimizations/README.md                            # 总览索引
docs/optimizations/step1-disable-pet-recognition.md     # Step 1 规划+完成回标
docs/optimizations/step2-timeline-group-by-day.md       # Step 2
docs/optimizations/step3-share-qr-code.md               # Step 3
docs/optimizations/step4-pet-role-silent-sync.md        # Step 4
docs/optimizations/step5-save-photo-to-gallery.md       # Step 5
docs/optimizations/COMPLETION_REPORT.md                 # 本文件
frontend/lib/services/photo_saver.dart                  # Step 5 单文件 helper
frontend/lib/services/share_link.dart                   # Step 3 协议解析
frontend/lib/utils/api_error.dart                       # Step 4 统一权限错判断
frontend/lib/widgets/share_qr_card.dart                 # Step 3 QR 卡片 widget
frontend/lib/screens/profile/share/share_qr_preview_screen.dart  # Step 3 预览页
frontend/lib/screens/profile/share/share_scan_screen.dart        # Step 3 扫码页
```

### 修改（17 文件）

```
backend/app/schemas/photo.py                            # Step 2 注释
backend/app/services/timeline.py                        # Step 2 day grouping
frontend/pubspec.yaml                                   # Step 3+5 新依赖
frontend/android/app/src/main/AndroidManifest.xml       # Step 3+5 权限
frontend/ios/Runner/Info.plist                          # Step 3+5 权限文案
frontend/lib/app.dart                                   # Step 4 lifecycle silentRefresh
frontend/lib/config/constants.dart                      # Step 1 flag + Step 3 share* 常量
frontend/lib/models/timeline.dart                       # Step 2 dayKey getter
frontend/lib/providers/pet_provider.dart                # Step 4 silentRefresh + diff
frontend/lib/providers/timeline_provider.dart           # Step 2 regroupByDay
frontend/lib/screens/profile/pet_edit_screen.dart       # Step 3 redeem sheet + Step 4 silentRefresh + 权限催
frontend/lib/screens/profile/pet_manage_screen.dart     # Step 4 升级 ConsumerStateful + silentRefresh
frontend/lib/screens/profile/share/pet_share_detail_screen.dart  # Step 3 QR 按钮 + Step 4 silentRefresh
frontend/lib/screens/record/record_screen.dart          # Step 1 删除 classifier 调用 + Step 4 权限催
frontend/lib/screens/timeline/photo_viewer_screen.dart  # Step 4 权限催 + Step 5 save sheet
frontend/lib/screens/timeline/timeline_screen.dart      # Step 2 day key + Step 4 权限催 + Step 5 save sheet
frontend/lib/services/share_service.dart                # Step 3 SHARE_QR_INVALID 文案
```

### 未改但顺手保留

- `backend/app/services/image_recognition.py`、`backend/app/config.py::ENABLE_SERVER_PET_RECOGNITION`、`frontend/lib/services/pet_classifier.dart`、`assets/models/pet_classifier.tflite`、`pubspec.yaml::tflite_flutter/image` —— Step 1 决定保留以备未来恢复。
- `backend/tests/api/test_photos.py::test_..._recognize` 中的 `monkeypatch.setattr(settings, "ENABLE_SERVER_PET_RECOGNITION", True)` 仍然通过，证明后端识别开关翻 true 仍可恢复服务器侧识别。

## 3. 风险清单（按严重度）

### R1 · 高 · 域名 `dangdangdiary.app` 是占位 (Step 3)

QR payload 用了 `https://dangdangdiary.app/s/<code>`，且 `shareLinkHosts` 白名单也以此为基础。**真实域名买定后必须在 `frontend/lib/config/constants.dart` 一次性更新**：
- `shareLinkBaseUrl` 改为新前缀
- `shareLinkHosts` 至少在过渡期同时保留旧域名 + 新域名，老 QR 才能继续识别

不操作的后果：未来真实域名上线后，新生成的 QR 仍指向 `dangdangdiary.app`；如果该域名被别人注册并跳到钓鱼站点，扫码用户跳过去会看到非当当日记的内容（不影响 App 内 redeem，但影响品牌）。

### R2 · 高 · 前端未通过 `flutter analyze` / `flutter test` 验证

本机 `flutter` 命令不可用（`Command 'flutter' not found`）。所有 Dart 改动均通过：
- `ReadLints` 静态检查（IDE 内置 analyzer，无报错）
- 手动 import / 类型 / API 签名 review
- 后端 pytest 间接验证 API 契约对齐

**人测前请先：**
```bash
cd frontend
flutter pub get          # 验证 3 个新依赖（saver_gallery 4.1.1 / qr_flutter 4.1.0 / mobile_scanner 7.2.0）可解析
flutter analyze          # 拉一次本机 analyzer，确认无 warning
flutter run -d <device>  # 真机或模拟器跑一次冷启动
```

若 `pub get` 因为传递依赖冲突卡住，最大嫌疑是 `mobile_scanner 7.2.0` 与项目里 `image_picker_android 0.8.x`（间接锁定的 androidx camera 版本）有冲突 —— 可以试着把 `mobile_scanner` 降到 `^6.0.0` 或最新 6.x 的稳定版。

### R3 · 中 · `groups[].date` 是破坏性协议变更 (Step 2)

后端响应 `TimelineGroup.date` 由 `"YYYY-MM"` 变为 `"YYYY-MM-DD"`。**前后端必须同步发布**：
- 后端先发：旧客户端 `TimelineMerge.monthKey` 仍按 `takenAt` 自行重排（不依赖服务端 `date` 字段），不崩，但 calendar 视图 group header 会显示成 `"2026年5月23日"`（前端 monthLabel 解析时拿不到第二位），结果是把日字符串当月解析；理论上会显示 `"2026年5"`（取前 7 位后 split-by-`-`），不好看但不崩。
- 旧后端 + 新客户端：`rebuildMonthIndex` 用 `substring(0,7)`，老的 `"YYYY-MM"` 长度=7 → `substring(0,7)` 返回原字符串，再当 month 前缀用，相当于自然退化为按月分组，也不崩。

总体推荐**原子发布**（后端 deploy 完立刻 push frontend OTA / 应用商店 update）。

### R4 · 中 · `saver_gallery` Android 旧版本权限弹窗 (Step 5)

`photo_saver.dart::_ensureGalleryPermission()` 的 Android 分支调 `Permission.storage.request()`：
- Android Q+（SDK 29+）该 API 在 Manifest 中 maxSdk=28 + 没声明对应权限时**直接返回 denied 而不弹窗**。我把判断改为「只要不是 `permanentlyDenied` 就放行」，绕过该坑。
- Android 9-（SDK ≤28）才真正弹 WRITE_EXTERNAL_STORAGE 弹窗。

如果运营数据显示用户主要在 Android 11+ 设备上，这个分支几乎永远走 "denied + 放行 + MediaStore 写入成功" 路径，体验是无声保存——这是预期。但如果 saver_gallery 4.1.1 在某些 OEM ROM（小米 / 华为 / OPPO）上把 MediaStore 写入失败时也返回 `isSuccess=false` 但 `errorMessage` 为空，会触发 "保存失败，请检查相册权限" 误导文案。**实机覆盖国内主流 ROM 一遍**。

### R5 · 中 · `mobile_scanner` 7.x API 版本敏感 (Step 3)

7.x 与 5.x/6.x 在以下方面有差异：
- `MobileScannerController.analyzeImage(filePath)` 返回 `Future<BarcodeCapture?>`（5.x 是 `Future<BarcodeCapture?>` 在 macOS/iOS 限定，部分 6.x 早期版本返回 `Future<bool>`）。
- `onDetect: (BarcodeCapture capture)` 签名固定。

我按 7.2 文档实现。**首次 `flutter pub get` 后看一眼 `mobile_scanner` 的 `analyzeImage` 签名是否真的是 `Future<BarcodeCapture?>`**，若返回类型变了（比如 `Future<void>` + 通过 stream 推送结果），需要按实际版本调整 `share_scan_screen.dart::_pickFromGallery` 和 `share_scan_screen.dart::pickShareCodeFromGallery` 两处。

### R6 · 低 · Step 4 health 模块写操作未统一文案

`lib/screens/health/{deworming,vaccination,weight,routine}_*.dart` 中的 add/edit/delete 写操作在 owner 撤回 editor 权限后仍然显示 `保存失败: DioException 403` 老文案，而不是 step4 统一的「权限已更新，请重试」。理由：
- 修改面大（10 个屏幕的多个 catch 块），单独提交可显著降低本批次回归风险；
- 现有文案虽然不友好，但**不影响功能**：用户重启 App 或下拉刷新仍可继续操作；
- silentRefresh 已经在 App.resumed 时统一触发，所以"权限刚被撤"的用户下次进入 health 写操作前 99% 已经有了正确的最新 role，UI 上的 add/edit 按钮会按 role 灰掉，根本走不到 403。

可以作为后续 small cleanup 单 PR 跟进。

### R7 · 低 · Step 1 包大小未减

`assets/models/pet_classifier.tflite` ≈ 1.7 MB 仍随包发布；`tflite_flutter` 和 `image` 依赖仍在 pubspec。按 Step 1 决策保留，可未来一并删。

### R8 · 低 · saver_gallery / mobile_scanner / qr_flutter 都是 BSD/MIT，但 mobile_scanner 7.x 依赖 ML Kit Barcode SDK

ML Kit Barcode 默认 bundled 模式会**让 APK 增大约 3-10 MB**。若包大小敏感，按 mobile_scanner 文档加 `dev.steenbakker.mobile_scanner.useUnbundled=true` 到 `android/gradle.properties` 把它切到 Google Play Services 动态下载。**国内分发**（不走 Google Play）则继续 bundled 更稳。

### R9 · 低 · `pet_provider.silentRefresh` 假设服务端 pet 顺序稳定

`_petListResultEquals` 按位置对齐比较 pet，依赖后端 `created_at desc` 的稳定排序。若未来后端引入 "owner 在前 / 共享在后" 之类的排序变更，会产生 false diff（每次都判定为变化）→ 每次都触发 UI rebuild。后果：rebuild 本身不会让用户看到 loading（因为不进入 AsyncLoading），但浪费一些 build / element diff 工作。**修复方法**：在 `_petListResultEquals` 中按 id 升序排两边 list 再比对。本次不做。

## 4. 必须人测项

按优先级排序，**上线前必过**：

### P0 · Step 3 二维码全链路（依赖新平台权限 + 新依赖）

| # | 角色 | 操作 | 预期 |
|---|------|------|------|
| 1 | Owner | 进入「档案分享」页 → 看到「分享给好友 (QR 码)」按钮 | 出现，过期时灰 |
| 2 | Owner | 点按钮 → 看到 QR 卡片预览 | Logo + 当当日记字样 + 宠物名 + 8 位码（4-4 排）+ 过期时间 + QR 居中 |
| 3 | Owner | 点「保存到相册」首次 | iOS 弹 Add-Only 权限请求；同意后 SnackBar 「已保存到相册」 |
| 4 | Owner | 打开系统相册 | 在 `Pictures/DangDangDiary/` 下看到 `dangdang_share_<code>.png`，分辨率约 1080 px |
| 5 | 接受者 | 「添加宠物档案」→「通过分享码 / 二维码添加」→「扫一扫」 | 弹相机权限；同意后 live preview |
| 6 | 接受者 | 对准上一步保存的 QR | 自动 pop 回，pet list 出现新档案 |
| 7 | 接受者 | 对准任意非当当日记 QR（微信群名片/Wi-Fi/支付宝/公众号） | SnackBar「这不是一张当当日记的分享码」，**不**误 redeem |
| 8 | 接受者 | 「从相册选择二维码」→ 选第一步保存的 PNG | 直接 redeem 成功 |
| 9 | 接受者 | 「从相册选择二维码」→ 选不含 QR 的风景照 | SnackBar「图片中没有识别到当当日记的分享码」 |
| 10 | 接受者 | 「手动输入分享码」 | 现有 8 位输入 dialog，与改动前一致 |

### P0 · Step 4 双账号权限实时感知（修复主诉求 bug）

| # | 操作 | 预期 |
|---|------|------|
| 1 | A 主人 / B viewer 已加入档案 X | B 进入 X 编辑页：badge=viewer，输入框只读，无保存按钮 |
| 2 | 不退出 B 任何页面，A 把 B 改为 editor | A 这边 SnackBar「已授予 B 编辑权限」 |
| 3 | B 立刻返回 pet manage 列表 → 再进 X 编辑 | **不闪 loading**，直接看到 editor badge，输入框可编辑，保存按钮出现 |
| 4 | 再循环一次：B 把 App 切到后台 → 切回前台 | 列表无 loading，role 已是 editor |
| 5 | B 在 editor 状态下，A 把 B 改回 viewer | B 不退出页面继续操作；点编辑保存 → SnackBar「权限已更新，请重试」，下次进入编辑页 role 已是 viewer |
| 6 | B 在时间轴长按删除一张 A 撤权前已上传的照片，恰逢 A 刚撤权 | SnackBar「权限已更新，请重试」，下次列表显示无删除入口（pet role 已 silentRefresh） |

### P1 · Step 1 + Step 2 + Step 5 单账号回归

| # | 操作 | 预期 |
|---|------|------|
| 1 | 从相册选 1 张风景照（非猫狗）上传 | **不再**弹「正在识别照片...」对话框，**不再**弹「未识别到猫狗」SnackBar；卡片立刻出现 |
| 2 | 相机拍一张白墙上传 | 同上，立刻进入卡片 |
| 3 | 提交 5 张混合内容上传 | 上传 dialog 文案显示「正在处理上传... / 服务器正在保存」，全部成功 |
| 4 | 时间轴 calendar 视图，连续 3 张同一天的照片 | 显示为一个 `"2026年X月Y日 (3)"` group |
| 5 | 该 group 上下相邻的空日子 | **不显示** |
| 6 | 右侧月级 scrollbar 拖到某月 | 正文滚动到该月最新一天的 day group 顶部 |
| 7 | 删一张照片：所在 day group 剩 0 张 | 该 group 整组消失 |
| 8 | 时间轴长按某张 → bottom sheet | 出现「保存到相册」（在多选之后、删除之前） |
| 9 | 点保存 | 「正在保存...」→「已保存到相册」；相册里看到原图（非缩略图） |
| 10 | 大图查看器长按 → bottom sheet | 同样有「保存到相册」选项，行为一致 |

### P2 · 平台兼容回归

- iOS 15 / iOS 17 各跑一台真机过 P0+P1
- Android 11 / Android 14 各跑一台真机过 P0+P1（小米 / 华为各一台尤其重要，覆盖 R4 中的 OEM 风险）
- 中文输入法在「手动输入分享码」dialog 中能否被前端 IME pattern 拦掉（按现有逻辑只允许 A-Z0-9 + 自动转大写）

## 5. 部署提示

1. **后端先 deploy**：Step 2 改了 `groups[].date` 字段含义，但旧客户端不会崩（见 R3）。Step 4 / Step 1 / Step 5 后端无改动。
2. **前端紧随其后发版**：把所有 5 个 step 的前端改动一起打成新版本 release。
3. **真实域名变更（R1）**：只改一处 `lib/config/constants.dart::shareLinkBaseUrl + shareLinkHosts`。**老 QR 卡片仍能识别**（host 白名单兜底）。
4. **monkeypatch 测试不变**：`backend/tests/api/test_photos.py::test_..._recognize` 仍然通过，说明翻 `ENABLE_SERVER_PET_RECOGNITION=true` 后服务端识别仍可恢复，回退路径完整。

## 6. 待办（不影响本次上线，但推荐近期内做）

- [ ] **R1**：买定真实域名后更新 `shareLinkBaseUrl` / `shareLinkHosts`
- [ ] **R2**：在装了 Flutter 的开发机上跑 `flutter analyze` + `flutter test`（如果有 widget test）
- [ ] **R6**：把 Step 4 的 `isPermissionError` + silentRefresh + 「权限已更新，请重试」统一文案铺到 `lib/screens/health/*` 10 个写操作
- [ ] **R8**：决定 mobile_scanner 是 bundled (省下载时间 / 包大 3-10MB) 还是 unbundled (体积小但首次扫码需要下载 Google Play Services 组件)
- [ ] **R9**：若 silentRefresh 在生产数据上发现频繁误判 diff，加 id-排序后比对

---

报告生成时间：2026-05-23 00:47 (UTC+8)
