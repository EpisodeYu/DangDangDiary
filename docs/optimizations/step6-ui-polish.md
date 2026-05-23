# Optimization Step 6 · 前端质感提升（无美工方案）

> 状态：🟡 第一轮已落地（commit `572d139`, `163994f`）；放大方案（§5）已规划但**尚未实施**，按需取用。
>
> 落地时间：2026-05-23
>
> 主张：APP 现在过于 Material 默认，AI/工业感重。在「不依赖美工 / 不引入字体 / 不引入插画包」的约束下，能做的最大质感升级是改图标、加动效、改卡片、加骨架屏。

## 1. 背景与目标

- **观感问题**：当前 UI 全是 Material 默认皮 —— 灰色 `Icons.photo_library_outlined` 空状态、12px 圆角无层次卡片、`CircularProgressIndicator` 转圈、所有页面切换无动画。色板（暖桃橘）虽对，但执行偏冷。
- **约束**：不动美工预算；不引入字体（APK 不增大）；不引入插画素材；只用代码层面能做的事。
- **目标方向**：温暖手账 / 童趣插画风。已选定。

## 2. 第一轮已落地

详见 commit `572d139` ("feat(ui): polish phase — rounded icons, soft cards, list stagger, skeletons") + `163994f` (去掉胶带旋转)。

| 改动 | 落地点 | 视觉强度（事后评估） |
|------|--------|-----------------------|
| **底栏改造** | [`main_scaffold.dart`](../../frontend/lib/widgets/main_scaffold.dart) 自绘 4-cell NavBar，选中态 AnimatedScale 1.0→1.08 + 桃橘色软底色块 + `HapticFeedback.selectionClick()` | **高** |
| **时间轴日期胶带** | 新建 [`tape_label.dart`](../../frontend/lib/widgets/tape_label.dart) CustomPaint，半透明桃橘底 + 两端白色"撕痕"斜纹（不旋转） | **高** |
| **列表入场动画** | 时间轴日历前 8 张照片 + 宠物管理前 6 张卡片，`flutter_animate` fadeIn + slideY stagger | **中**（只在首次） |
| **加载骨架屏** | 新建 [`skeleton.dart`](../../frontend/lib/widgets/skeleton.dart)；时间轴 / 健康四 tab / 宠物 / 分享列表的初次加载替换 `CircularProgressIndicator` | **中**（只在加载时） |
| **提交 haptic** | 记录页 `_submit()` 加 `HapticFeedback.mediumImpact()` | **低** |
| **Material outlined → rounded** | 全 App ~120 处图标改用 `*_rounded` 变体 | **极低**（差异 5% 级） |
| **卡片 radius + 双层柔阴影** | 全局 12→16；新建 [`app_card.dart`](../../frontend/lib/widgets/app_card.dart) 提供 `AppCard`、`kAppSoftShadow`、`kAppLiftedShadow`；主要卡片转 AppCard | **极低**（阴影 alpha 0.04+0.05） |
| **Dialog/BottomSheet/输入框圆角** | theme.dart 全局 14/16/20 | **极低** |

新依赖：`flutter_animate ^4.5.2`、`shimmer ^3.0.0`。

放弃：`phosphor_flutter ^2.1.0`（在 Flutter 3.44 下 `class PhosphorIconData extends IconData` 编译失败 —— IconData 已被 sealed `final` 化；pub.dev 无维护中 fork）。

### 2.1 实测反馈

用户回报「除了胶带和某个图标变了，其他没感觉」。诚实复盘：

- **底栏弹性 + haptic**：动作要触发才能感知，静态截图不可见；但确实做了
- **列表 stagger**：只在冷启动 / 切 tab 回来时出现，240ms 一闪而过
- **骨架屏**：本地网络下加载 <200ms，骨架几乎不显
- **rounded 图标 / 卡片阴影 / 圆角**：差异 5px 级别，肉眼几乎区分不出

结论：**第一轮里 60% 的代码量贡献了 <10% 的感官变化**。下一轮如果要做，必须拉高振幅。

## 3. 文件清单（第一轮）

### 新建

```
frontend/lib/widgets/app_card.dart         # AppCard + 双层柔阴影常量
frontend/lib/widgets/skeleton.dart         # 骨架屏组件库
frontend/lib/widgets/tape_label.dart       # 胶带日期标签（CustomPaint，无 SVG）
frontend/lib/widgets/tappable_scale.dart   # 公用按下缩放 + haptic（已写未广泛接入）
docs/optimizations/step6-ui-polish.md      # 本文件
```

### 修改

```
frontend/pubspec.yaml                                  # +flutter_animate +shimmer
frontend/lib/config/theme.dart                         # 全局 radius 升级 + Dialog/Sheet/Input 圆角
frontend/lib/widgets/main_scaffold.dart                # 自绘 NavBar (rewrite 67%)
frontend/lib/widgets/{photo_grid_tile, photo_picker_grid,
  immersive_photo_tile, original_photo_image,
  pet_chip_dropdown, pet_selector,
  voice_intake_sheet, voice_record_button}.dart       # 图标 + 部分骨架
frontend/lib/screens/auth/login_screen.dart            # 图标
frontend/lib/screens/health/{
  deworming_tab, routine_tab, vaccination_tab, weight_tab,
  deworming_record_screen, routine_record_screen,
  vaccination_record_screen, weight_record_screen,
  health_screen}.dart                                  # 图标 + 健康骨架
frontend/lib/screens/profile/{
  pet_edit_screen, pet_manage_screen, profile_screen,
  share/{pet_share_detail, pet_share_list,
         share_qr_preview, share_scan}_screen}.dart   # 图标 + AppCard + 骨架
frontend/lib/screens/record/record_screen.dart         # 图标 + AppCard + haptic
frontend/lib/screens/timeline/{timeline, photo_viewer}_screen.dart
                                                       # 图标 + 胶带 + 骨架 + 列表动画
frontend/test/widgets/pet_chip_dropdown_test.dart      # Icons.arrow_drop_down → _rounded
```

## 4. 验证

- `flutter analyze`：0 error，1 pre-existing info（`${permissionMessage}` 大括号，与 commit `7ce3790` 引入，本轮不动）
- `flutter test`：43 passed / 3 pre-existing failed（`TimelineMerge.mergeWindow` 三个用例断言月 key 但 step2 已改成日 key，stash 验证非本轮引入）
- `flutter build apk` 未跑（本机无 Android SDK）。Dart 层 100% 编译通过，平台层无新依赖风险，但**真机 visual review 必需**

## 5. 第二轮放大方案（菜单，按需取用）

下面六项**两两独立**，可以单选 / 组合。所有方案都「无新美工资源、无新字体、无新插画」，只是把第一轮做保守的几个旋钮往上拧。

> 实施提示：建议**单选 1-2 项实施 + 立刻出 build review**，避免第一轮的"全部做小一点点"翻车。

### 5.1 阴影 / radius 振幅拉高（推荐优先做）

**改动**：
- `kAppSoftShadow` alpha 从 `0.04 + 0.05` → `0.08 + 0.10`，blur 从 12/28 → 16/40
- `kAppLiftedShadow` alpha 从 `0.06 + 0.07` → `0.12 + 0.14`，blur 从 16/40 → 24/56
- 全局卡片 radius 16 → 20，按钮 14 → 16

**效果**：卡片明显从背景"浮起来"，向 "fluffy" 风（小红书 / Keep 宠物板块的视觉）靠拢。
**风险**：阴影过重在低端机上 raster 略慢；浅米色背景下还可以。
**工作量**：单文件改 4 个常量 + 1 个 theme 字段，10 分钟。

### 5.2 背景色从纯白切到浅派塔米色 #FBF3EC（推荐和 5.1 一起做）

**改动**：
- [`theme.dart`](../../frontend/lib/config/theme.dart) `backgroundColor` `#FFF8F5` → `#FBF3EC`（更黄、更暖）
- 卡片 `surfaceColor` 保持纯白

**效果**：背景与卡片有色差，卡片才能 "pop"。这是 §5.1 阴影改造的必要伴侣 —— 在纯白底上加深阴影，反而显脏。
**风险**：所有页面背景色都会变，需要复检截图。
**工作量**：单常量改 1 个字符，5 分钟。

### 5.3 页面切换 FadeThrough 过渡

**改动**：在 [`router.dart`](../../frontend/lib/config/router.dart) 给每个 `GoRoute` 加 `pageBuilder` 返回 `CustomTransitionPage`，使用 Material 3 的 `FadeThroughTransition`（来自 `animations` 包）或自定义 `FadeTransition + ScaleTransition`。

**效果**：页面之间不再是默认右滑硬切，而是软淡入。每次点详情、点设置都能感受到。
**风险**：嵌入 `StatefulShellRoute`（底栏切换）时要小心，可能要分别处理 shell-level 和 leaf-level transition。
**新依赖**：`animations ^2.0.11`（Flutter 团队官方维护，~30KB）。可选，也能纯代码自己写一个简易 FadeThrough。
**工作量**：30 分钟到 1 小时。

### 5.4 列表动画"加大"

**改动**：
- 时间轴日历：stagger 间隔从 24ms → 60ms，覆盖范围从前 8 张 → 前 16 张，slideY `begin: 0.06` → `0.16`
- 时间轴沉浸模式 + 健康四 tab 列表 + 分享列表也接入相同 stagger
- 沉浸模式每张照片入场时附带 `.scale(begin: 0.95)` 让"长大"

**效果**：动效在每个列表都明显存在，比"只在时间轴有"更整体感。
**风险**：在长列表下高频 tween 可能掉帧；保留 stagger 上限。
**工作量**：1 小时（每个列表 widget 单独接入）。

### 5.5 图标包换 Material Symbols

**改动**：引入 `material_symbols_icons ^4.x`（Google 官方维护，Flutter 3.44 兼容），全 App 图标改用 `Symbols.x_rounded` 系。

**效果**：Material Symbols 比 Material Icons 更新很多，且支持可变字重 / fill / weight 调节。Symbols 的 rounded 变体明显比 Icons 的 rounded 更圆，差异 30%+ 级。
**风险**：包体积 +1.5MB（已包含 Tree-shake，最终 APK 仅打包用到的图标）。
**新依赖**：`material_symbols_icons`（MIT，活跃）。
**工作量**：90% sed 机械替换（参考第一轮 phosphor 回退的方法），剩 10% 手动修；2 小时。

### 5.6 Tab 区域差异化色彩

**改动**：每个底栏 Tab 进入后，对应 `Scaffold` 的 `AppBar background` + `FAB color` + 「选中色」从单一桃橘 → 四种 accent：

| Tab | accent 色 |
|-----|-----------|
| 记录 | 桃橘 `#FF8B6A`（保持） |
| 健康 | 薄荷绿 `#7FCFB7` |
| 时间轴 | 淡紫 `#B9A0E0` |
| 我的 | 米奶油 `#E8C896` |

**效果**：用户立刻能用"哪个颜色"识别现在在哪个 Tab。增强产品记忆点。
**风险**：审美上可能"花"，特别在小屏；需要先做一版让你审视。
**工作量**：30 分钟（把 `AppTheme.primaryColor` 改成由 currentRoute 派生的 `accentForTab(route)`）。

## 6. 还可以但本轮不规划的事

- **A. 中文字体**：`霞鹜文楷` 标题 + `MiSans` 正文。需下载字体文件入 `assets/fonts/`，APK +1-3MB。**质感升级最大的单点**，但不在"无美工"范畴。
- **C. 空状态插画**：AI 生图 4-6 张统一风格 SVG 替换灰色 Material icon。需要锁定 prompt 风格。
- **D. 文案温度化**：30 处「说明书风」 → 「日记风」。0 资源，但需要逐句过审遣词。

这三件单独走一份新的 step doc 规划，不在这里展开。

## 7. 推荐二轮组合

> 如果只能做一件：**§5.1 阴影振幅** + **§5.2 背景米色**（必须打包做）。10 分钟工作量，可见度提升明显。
>
> 如果有半天：再加 **§5.3 页面切换 FadeThrough**。
>
> 如果有一天：全做 §5.1–§5.4。**避免 §5.5（图标包又换）+ §5.6（多色 Tab）** —— 这两项耦合多、审美风险大，单独评审。
