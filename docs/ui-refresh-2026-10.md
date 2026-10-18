# 全界面优化 · 2026-10

## 已确认方向

- 温暖治愈，保留品牌桃橘主色 `#FF8B6A` 和杏色 `#FFC3A0`。
- 可以调整同页排版、间距、卡片和按钮；保留入口、导航、操作顺序和业务流程。
- 少量轻柔动效；不引入字体包、图片包或新运行时依赖。
- 完成全面验证后提交 commit。

## 界面变化

- 暖纸色背景、深暖色正文、可读的强调色，统一卡片、输入框、按钮、弹窗、底部面板和提示样式。
- 记录页突出照片入口；语音录制仍使用底部居中的长按按钮，并保留录音浮层的显示空间。
- 健康页将四个分类独立成一行，宠物选择器支持长名称；统一摘要、历史记录及空/错误状态。
- 四种健康表单使用滚动布局，保持字段顺序和原有提交回调；周期表单适配小屏和大字体。
- 时间轴保留日历/沉浸、筛选、多选、查看原图和照片操作；照片网格按宽度排版，扩大手机上的照片展示面积。
- “我的”、档案管理、档案编辑、分享页面统一标题层级、头像区域、分组和角色标识。
- 下载档案弹窗补充选项说明；仍默认勾选照片和记录、至少选择一项、取消/下载及保存位置选择流程不变。
- 登录标志只播放一次轻柔入场；导航、列表和骨架屏尊重系统减少动态效果设置。
- 语音确认面板统一选项样式，长宠物名收起显示；小屏、大字号和键盘展开时可以滚动查看字段和操作按钮。

本次未修改后端接口、模型、服务、状态管理、权限判断或路由配置。原图查看器和扫码页面继续使用原有专用显示方式。

## 验证方式

`test/screens/ui_layout_test.dart` 包含 21 个页面和 4 类语音确认表单在 390×844、320×640（1.5 倍字号）下的布局检查，以及长名称、长疫苗名称、空状态、重试、健康分类切换、日期选择、表单校验和三种档案角色的操作检查。另有语音面板在键盘展开后的滚动及取消草稿检查。

```powershell
flutter analyze --no-pub
flutter test --no-pub --concurrency=1
# 可选：使用本机中文字体生成界面检查截图，不将字体打包进 App
flutter test test/screens/ui_layout_test.dart --no-pub --concurrency=1 --dart-define=UI_CAPTURE=build/ui-review --dart-define=UI_FONT=C:/Windows/Fonts/msyh.ttc
```

`integration_test/ui_review_test.dart` 使用真实路由及 Android 插件，配合本地合成数据检查主导航、照片菜单、健康录入、系统键盘、原图查看、多选、沉浸模式、档案管理、导出弹窗和分享二维码。测试照片使用项目品牌图，不连接生产服务。

```powershell
flutter drive --driver=test_driver/ui_review_driver.dart --target=integration_test/ui_review_test.dart -d 127.0.0.1:5555 --no-dds
```

设备截图保存在 `frontend/build/ui-native-review/`；组件截图保存在 `frontend/build/ui-review/`，均不纳入版本控制。原有导出原生保存流程可继续通过 `scripts/run_export_integration.py` 验证。

## 本机验证结果（2026-10-18）

环境：Windows、Flutter 3.44.0 / Dart 3.12.0、Android 15 模拟器。构建和测试串行执行。

| 检查 | 结果 |
| --- | --- |
| `flutter analyze --no-pub` | 无问题 |
| 完整 Flutter 测试 | 130 项通过，包含新增的 65 项界面与交互检查 |
| 普通字号、小屏 1.5 倍字号截图 | 已复核，覆盖长名称、周期表单、语音表单、弹窗及空状态 |
| Android 主流程集成测试 | 通过，14 张运行时界面截图已复核；修复照片查看器深色背景上的标题和返回按钮对比问题 |
| Android 档案导出集成测试 | 主人、编辑、查看三种角色及取消保存均通过；三个 ZIP 的原图字节、CRC 和健康 JSON 校验通过 |
| 后端完整测试 `python -X utf8 -m pytest -q` | 194 项通过 |
| Android release 构建 | 通过；安装并冷启动成功，登录页系统键盘展开后可滚动到登录按钮 |

测试安装包位于 `frontend/build/app/outputs/flutter-apk/app-release.apk`，沿用仓库现有调试签名，未配置应用商店发布签名。实际启动和系统键盘截图为 `ui-native-review/15-release-login.png` 至 `17-release-keyboard-scroll.png`。

Windows 无法执行 iOS 原生构建和设备验证；本轮移动端原生验证使用 Android 模拟器。后端测试沿用仓库的隔离 SQLite 及外部服务模拟，不代表 PostgreSQL/MinIO 生产环境联调。相机、真实短信和云端语音识别仍需使用实际设备及服务，本次不发送真实短信或操作生产数据。

后端完整回归曾暴露 `test_tampered_payload_returns_none` 的偶发失败：修改 Base64URL 签名末尾字符可能只改变未使用的填充位，实际签名字节相同。现改为修改首字符并更名为 `test_tampered_signature_returns_none`，确保测试确实篡改签名；鉴权实现未改动。

切换 Android 集成测试与 release 构建时，不加 `--no-pub`（例如 `flutter build apk --release --dart-define=BASE_URL=https://YOUR_SERVER_HOST`）。本机 Flutter 3.44 的 `--no-pub` 也跳过平台插件注册文件再生成，会留下上一种构建模式的注册代码；正常构建会按模式处理开发依赖。导出集成测试脚本也已调整，支持从 release 模式切回测试模式。

## 登录页与 APK 配置修正

- 按反馈移除登录表单中的“欢迎回家”及“用手机号，开启相伴的日常”，保留品牌区域、输入框与登录流程。
- 上次 APK 构建遗漏 `BASE_URL`，使用默认 `http://127.0.0.1`，在 Android 上指向设备自身。先前的 release 检查仅验证安装、启动与键盘布局，未验证真实服务器连接。
- Android release 构建新增必填参数及入口格式检查；正确命令见 `dev-commands.md`。联网权限和 HTTP 配置原本已具备，无需修改。
- 增加单独运行的 Android 实际接口检查 `integration_test/api_connectivity_test.dart`：使用 App 的真实客户端与正常 TLS 校验，无令牌请求 `/api/v1/auth/me`，断言后端返回 `401 / INVALID_ACCESS_TOKEN`。不发送短信、不修改生产数据。
- 本机部署入口保存在被 Git 忽略的 `frontend/release.env.local`，后续可通过 `--dart-define-from-file=release.env.local` 复用；真实域名未写入代码或文档示例。
- 修正验证：静态检查无问题，130 项 Flutter 测试通过；390×844 与 320×640（1.5 倍字号）登录页截图复核通过；缺少 `BASE_URL` 的 release 构建按预期被拦截；Android 15 模拟器中的实际 HTTPS 接口检查通过。
- Release APK 构建及 v2 签名校验通过，三个 ABI 的编译产物均包含已验证的 HTTPS 入口且不再包含被移除文案；Android 安装、冷启动与登录页截图复核通过。APK 沿用现有调试签名。

## 页面顶部文案简化

- 在 `6fefaf1` 已提交且工作区干净的基础上继续修改。
- 移除记录页“把今天，留在这里”、我的页“相伴的日常”、宠物档案管理页“毛孩子的家”及对应说明；删除整块标题区域和其间距，照片入口、个人资料卡、宠物资料卡随之上移。
- 按“每页顶部文案”的要求，同步移除分享列表、分享详情、日常周期和驱虫周期设置页的同类顶部标题与说明。
- 页面导航标题、功能分组、字段提示、操作回调及权限保持原有行为；列表移除标题行后同步调整条目数量与索引。
- 验证：静态检查无问题，现有 65 项界面与交互测试通过；上述七个页面在普通屏幕及小屏 1.5 倍字号下的截图复核通过。截图位于本机 `frontend/build/page-intro-review/`。
