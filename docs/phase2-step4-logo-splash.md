# Phase 2 - Step 4: Logo UI 动画（Splash 与品牌复用）

## 项目背景

现在整个 App 没有 Logo 图像资源：

- [frontend/pubspec.yaml](../frontend/pubspec.yaml) 的 `assets:` 只声明了 `assets/models/`（TFLite 模型），没有任何 `assets/brand/` 或 `logo.png`。
- [frontend/lib/screens/auth/login_screen.dart](../frontend/lib/screens/auth/login_screen.dart) 第 98-106 行的 "Logo" 是一个 `Container(width:88, height:88, decoration: BoxDecoration(color: primary with alpha 0.12, borderRadius: 24))` 里塞了 `Icon(Icons.pets, size: 48)`，本质是 Material Icons。
- [frontend/android/app/src/main/res/drawable/launch_background.xml](../frontend/android/app/src/main/res/drawable/launch_background.xml) 是纯白背景（`@android:color/white`），bitmap 示例被注释掉了。
- iOS 侧 [frontend/ios/Runner/Base.lproj/LaunchScreen.storyboard](../frontend/ios/Runner/Base.lproj/LaunchScreen.storyboard) 也是 Flutter 默认白底。
- 路由初始地址是 `/record`（见 [frontend/lib/config/router.dart](../frontend/lib/config/router.dart) 第 38 行），`redirect` 里 `AuthStatus.unknown` 时直接 push `/login`——意味着冷启动会闪一下白屏 → Material 登录页。

本步骤目的：

1. 把 Logo 作为**真正的品牌资源**引入（矢量 SVG 主图 + 单色小图）。
2. 新建 Splash 路由，取代冷启动白屏 + "auth 未知时直接踢登录页" 的尴尬跳转，用短暂的品牌动画覆盖 auth 初始化期。
3. 在登录页、AppBar、加载态里复用同一套 Logo 资源和动画组件，形成品牌一致性。
4. 原生冷启动屏（Android `launch_background.xml` + iOS `LaunchScreen.storyboard`）统一改成品牌底色，彻底消灭白屏闪烁。

**所有动画用 Flutter 自带 `AnimationController` + `Tween` 实现，不引入 Lottie / Rive。** 包体积零增长。

**前置依赖**：Phase 1 全部完成。本步骤与 Phase 2 Step 2、Step 3 完全独立，可单独实现、单独 commit。推荐放在 Step 2、3 之后做，作为 Phase 2 UI 打磨期收官。

---

## 0. 与既有约定的关系

- **全局规则**（[docs/00-global-rules.md](00-global-rules.md)）：本步不改接口、不动数据库、不加 `.env` 键。
- **主题色**：严格使用 [frontend/lib/config/theme.dart](../frontend/lib/config/theme.dart) 的 `AppTheme.primaryColor = 0xFFFF8B6A`、`AppTheme.backgroundColor = 0xFFFFF8F5`；Logo 设计稿**必须**基于这组色 + 对比色绘制，不要引入第三组新颜色。
- **路由改动有影响面**：`initialLocation` 从 `/record` 改成 `/splash`，并改 `redirect` 规则以避开 Splash；一切现有的深链接（例如外部 SMS / 推送跳到 `/profile/pets/:id/edit`）不受影响——`redirect` 只拦截未登录态。

---

## 1. 素材规范

### 1.1 设计师需交付的文件清单

| 文件 | 用途 | 规格 |
|---|---|---|
| `logo.svg` | Splash / 登录页主 Logo | 单文件矢量，宽高比 1:1，viewBox 1024×1024； |
| `logo_mono.svg` | AppBar / 加载态小 Logo | 单色（`currentColor` 填充，允许代码覆盖颜色），viewBox 1024×1024 |
| `logo_1024.png` | 分享图 / App 市场 | 1024×1024 PNG 带透明通道，用于将来发布 |
| `logo_512.png` | Android adaptive icon 前景 | 512×512 带透明 |
| `logo_192.png` | 低端 Android 兼容 | 192×192 |
| `splash_bg.svg`（可选） | Splash 背景装饰（波浪 / 猫毛纹） | 如设计师觉得有需要，延伸 Logo 氛围 |

> 不要求交付 Lottie JSON / Rive；动画全部在 Flutter 代码里编排。

### 1.2 设计方向（给到设计师的 brief）

- 品牌调性：温暖、治愈、记录感；避免夸张卡通
- 主体：简化的猫 + 狗（左右排或重叠剪影）搭配笔尖 / 对折笔记本的符号元素
- 风格：现代 flat + 少量柔和圆角；线条以 12-18pt 等比例统一
- 可识别性：要能缩到 20×20 像素（AppBar 用）时仍读得出大致形态，因此细节不能太密
- 双形态：主彩色 SVG + `currentColor` 单色 SVG 两份必交付

### 1.3 文件摆放与 pubspec

目录：

```
frontend/
  assets/
    brand/
      logo.svg
      logo_mono.svg
      logo_1024.png
      logo_512.png
      logo_192.png
      splash_bg.svg       # optional
    models/
      ...（已有）
```

[frontend/pubspec.yaml](../frontend/pubspec.yaml) 修改：

```yaml
dependencies:
  flutter:
    sdk: flutter
  # ...（已有不变）
  # Vector assets for Logo / Splash (step4)
  flutter_svg: ^2.0.10+1

flutter:
  uses-material-design: true
  assets:
    - assets/models/
    - assets/brand/          # ← 新增
```

> `flutter_svg` 是唯一新增的第三方依赖；包体积增加 ≈ 150KB，小于一张高分辨率 PNG。

---

## 2. Splash 页

### 2.1 文件与路由

新建 [frontend/lib/screens/splash/splash_screen.dart](../frontend/lib/screens/splash/splash_screen.dart)。

路由 [frontend/lib/config/router.dart](../frontend/lib/config/router.dart) 改动：

```dart
// import
import '../screens/splash/splash_screen.dart';

// ...

return GoRouter(
  navigatorKey: _rootNavigatorKey,
  initialLocation: '/splash',              // ← 从 '/record' 改为 '/splash'
  refreshListenable: notifier,
  redirect: (context, state) {
    final auth = ref.read(authProvider);
    final isLoggedIn = auth.status == AuthStatus.authenticated;
    final isLoading = auth.status == AuthStatus.unknown;
    final loc = state.matchedLocation;
    final onSplash = loc == '/splash';
    final onLogin = loc == '/login';

    // Splash 自己决定何时跳走；redirect 在 Splash 停留期间不做任何拦截
    if (onSplash) return null;

    if (isLoading) return '/splash';       // 非 Splash 页遇到未决态，回去等
    if (!isLoggedIn && !onLogin) return '/login';
    if (isLoggedIn && onLogin) return '/record';
    return null;
  },
  routes: [
    GoRoute(
      path: '/splash',
      parentNavigatorKey: _rootNavigatorKey,
      builder: (context, state) => const SplashScreen(),
    ),
    GoRoute(
      path: '/login',
      builder: (context, state) => const LoginScreen(),
    ),
    // ...（其它路由不变）
  ],
);
```

注意：原 `redirect` 里 `if (isLoading) return onLogin ? null : '/login';` 的语义被**彻底替换**——之前 auth 未决时强踢登录页，现在改为回到 `/splash` 等 auth 就绪。

### 2.2 Splash 动画编排（绝对时间线）

总时长 1500ms（最短路径），遇到 auth 仍未就绪时进入 idle pulse 等待。

```
t=0 ms     ┬  Logo: scale 0.7 → 1.0, opacity 0 → 1
           │  Curves.easeOutBack
           │  _introController (0 → 900ms)
t=400 ms   │  Title "当当日记": translateY 16 → 0, opacity 0 → 1
           │  Curves.easeOut
t=900 ms   ┴
           ┬  Logo 呼吸：scale 1.0 → 1.06 → 1.0
           │  Curves.easeInOut, 1 次
           │  _idleController (900 → 1500ms)
t=1500 ms  ┴  → 判断 auth，决定跳 /login 还是 /record

if auth == unknown at t=1500:
    _idleController repeat()（2.4s / 次呼吸循环），继续等
```

### 2.3 Splash 实现骨架

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../providers/auth_provider.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _intro;
  late final AnimationController _idle;
  late final Animation<double> _logoScale;
  late final Animation<double> _logoOpacity;
  late final Animation<double> _titleOpacity;
  late final Animation<Offset> _titleSlide;
  late final Animation<double> _pulse;

  bool _routed = false;

  @override
  void initState() {
    super.initState();

    _intro = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _idle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );

    _logoScale = Tween<double>(begin: 0.7, end: 1.0).animate(
      CurvedAnimation(parent: _intro, curve: const Interval(0, 0.44, curve: Curves.easeOutBack)),
    );
    _logoOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _intro, curve: const Interval(0, 0.44, curve: Curves.easeOut)),
    );
    _titleSlide = Tween<Offset>(begin: const Offset(0, 0.3), end: Offset.zero).animate(
      CurvedAnimation(parent: _intro, curve: const Interval(0.44, 1.0, curve: Curves.easeOut)),
    );
    _titleOpacity = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _intro, curve: const Interval(0.44, 1.0, curve: Curves.easeOut)),
    );

    // Pulse: 0 → 1 → 0 in 2.4s, maps to scale 1.0 → 1.06 → 1.0
    _pulse = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.06), weight: 1),
      TweenSequenceItem(tween: Tween(begin: 1.06, end: 1.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _idle, curve: Curves.easeInOut));

    _startFlow();
  }

  Future<void> _startFlow() async {
    await _intro.forward();
    _idle.forward();

    // 最少展示 1500ms；之后看 auth 就绪与否
    final earliest = Future.delayed(const Duration(milliseconds: 600));
    await earliest;

    while (mounted && !_routed) {
      final auth = ref.read(authProvider);
      if (auth.status != AuthStatus.unknown) {
        _routed = true;
        // 把当前 pulse 动画跑完再跳，避免硬切
        if (_idle.isAnimating) {
          await _idle.forward();
        }
        if (!mounted) return;
        final isLoggedIn = auth.status == AuthStatus.authenticated;
        context.go(isLoggedIn ? '/record' : '/login');
        return;
      }
      // auth 仍未决，循环呼吸
      await _idle.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _intro.dispose();
    _idle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundColor,
      body: Center(
        child: AnimatedBuilder(
          animation: Listenable.merge([_intro, _idle]),
          builder: (context, _) {
            final scale = _logoScale.value * _pulse.value;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Opacity(
                  opacity: _logoOpacity.value,
                  child: Transform.scale(
                    scale: scale,
                    child: SvgPicture.asset(
                      'assets/brand/logo.svg',
                      width: 140,
                      height: 140,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                SlideTransition(
                  position: _titleSlide,
                  child: Opacity(
                    opacity: _titleOpacity.value,
                    child: const Text(
                      '当当日记',
                      style: TextStyle(
                        fontSize: 26,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.textPrimary,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Opacity(
                  opacity: _titleOpacity.value,
                  child: const Text(
                    '记录每一次陪伴',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppTheme.textSecondary,
                      letterSpacing: 1,
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}
```

要点：

- `_pulse.value` 在 intro 阶段恒为 1.0（`_idle` 未启动前 value 为 initial，TweenSequence 的初始为 1.0），所以 `scale = _logoScale.value * _pulse.value` 不会干扰 intro 动画。
- 至少展示 600ms 后再考虑跳走，避免 auth 已缓存导致 Splash 一闪而过的突兀感。
- `context.go` 而非 `push`，确保 Splash 不留在栈里。

---

## 3. 原生冷启动屏统一品牌底色

### 3.1 Android

修改 [frontend/android/app/src/main/res/drawable/launch_background.xml](../frontend/android/app/src/main/res/drawable/launch_background.xml)：

1. 在 [frontend/android/app/src/main/res/values/colors.xml](../frontend/android/app/src/main/res/values/colors.xml)（若不存在则新建）添加：
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <resources>
     <color name="brand_background">#FFF8F5</color>
   </resources>
   ```
2. `launch_background.xml` 改为：
   ```xml
   <?xml version="1.0" encoding="utf-8"?>
   <layer-list xmlns:android="http://schemas.android.com/apk/res/android">
       <item android:drawable="@color/brand_background" />
   </layer-list>
   ```

> 本步骤**不**在原生冷启动屏里放 Logo 图——Flutter 引擎拉起前用静态图意义不大，且容易和 Splash 的 Flutter 动画衔接不自然。只统一背景色就够了。

### 3.2 iOS

修改 [frontend/ios/Runner/Base.lproj/LaunchScreen.storyboard](../frontend/ios/Runner/Base.lproj/LaunchScreen.storyboard)：

把根 `View` 的 `backgroundColor` 从默认白改为 RGB `(1.0, 0.973, 0.961, 1.0)`（= `#FFF8F5`）。一般步骤：

1. 用 Xcode 打开 Runner workspace
2. 选 LaunchScreen.storyboard → 根 View → Background → Custom
3. 输入 Hex `FFF8F5` 或 RGB 值，保存

文档里同时给出纯文本替换方案（供 agent 未开 Xcode 时也能改成）：找到 `<view ... key="view" ...>` 标签内的 `<color key="backgroundColor" .../>`，把 `red="1" green="1" blue="1"` 改成 `red="1" green="0.973" blue="0.961"`。

### 3.3 iOS 设置 Info.plist

[frontend/ios/Runner/Info.plist](../frontend/ios/Runner/Info.plist) 无需改动（`UILaunchStoryboardName` 仍指向 LaunchScreen）。

---

## 4. 登录页 Logo 替换

[frontend/lib/screens/auth/login_screen.dart](../frontend/lib/screens/auth/login_screen.dart) 第 98-106 行：

**从**：

```dart
// ── Logo ──
Container(
  width: 88,
  height: 88,
  decoration: BoxDecoration(
    color: theme.colorScheme.primary.withValues(alpha: 0.12),
    borderRadius: BorderRadius.circular(24),
  ),
  child: Icon(Icons.pets, size: 48, color: theme.colorScheme.primary),
),
```

**改为**：

```dart
// ── Logo ──
const _LoginLogo(),
```

在同文件底部或抽到 [frontend/lib/widgets/login_logo.dart](../frontend/lib/widgets/login_logo.dart) 新增：

```dart
class _LoginLogo extends StatefulWidget {
  const _LoginLogo();
  @override
  State<_LoginLogo> createState() => _LoginLogoState();
}

class _LoginLogoState extends State<_LoginLogo> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _wobble;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 600))
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) {
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted) _c.forward(from: 0);
          });
        }
      });
    _wobble = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _c, curve: Curves.elasticOut),
    );
    // 初次进入轻摆一次
    WidgetsBinding.instance.addPostFrameCallback((_) => _c.forward());
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _wobble,
      builder: (context, _) {
        // 摆动范围 ±6°
        final angle = (_wobble.value - 0.5) * 0.21;  // ≈ 12° peak-to-peak
        return Transform.rotate(
          angle: angle,
          child: SvgPicture.asset(
            'assets/brand/logo.svg',
            width: 88,
            height: 88,
          ),
        );
      },
    );
  }
}
```

- 每 4 秒做一次轻摆，吸引注意力但不抢焦点。
- 去掉原先 `Container + BorderRadius` 的背景圈——SVG 本体已有设计，不需要额外容器。

---

## 5. AppBar 单色小 Logo

新建 [frontend/lib/widgets/brand_mark.dart](../frontend/lib/widgets/brand_mark.dart)：

```dart
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../config/theme.dart';

/// Small monochrome brand mark, sized for AppBar titles / lead slots.
///
/// Uses `logo_mono.svg` which is drawn with `currentColor`, so the [color]
/// parameter (defaults to [AppTheme.primaryColor]) takes effect via the
/// `colorFilter` pipeline.
class BrandMark extends StatelessWidget {
  final double size;
  final Color? color;
  const BrandMark({super.key, this.size = 20, this.color});

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/brand/logo_mono.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color ?? AppTheme.primaryColor, BlendMode.srcIn),
    );
  }
}
```

> AppBar 的复用位置留给实现 agent 自主判断：推荐至少在 **记录页** / **时间线页** / **健康页** 的 AppBar 左侧放一个 20px 的 `BrandMark`；全部放或全不放都可以，但应**整站保持一致**。

---

## 6. `BrandPulse` 品牌化加载组件

新建 [frontend/lib/widgets/brand_pulse.dart](../frontend/lib/widgets/brand_pulse.dart)：一个会呼吸的品牌 mark，替代 `CircularProgressIndicator`。

```dart
class BrandPulse extends StatefulWidget {
  final double size;
  const BrandPulse({super.key, this.size = 32});

  @override
  State<BrandPulse> createState() => _BrandPulseState();
}

class _BrandPulseState extends State<BrandPulse> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat(reverse: true);
  }
  @override
  void dispose() { _c.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        final t = _c.value; // 0 → 1 → 0
        final scale = 0.9 + 0.2 * t;
        final opacity = 0.5 + 0.5 * t;
        return Opacity(
          opacity: opacity,
          child: Transform.scale(scale: scale, child: BrandMark(size: widget.size)),
        );
      },
    );
  }
}
```

**替换范围（可选，渐进式）**：

- `record_screen.dart` 的 `_showRecognizingDialog` 里的 `CircularProgressIndicator` → `BrandPulse(size: 28)`
- `record_screen.dart` 的 `_showUploadDialog` 的 spinner 部分同理
- `pet_chip_dropdown.dart`（step3 新建组件）的 "识别中" 小 spinner 同理

**不强制一次全换**；本步骤只要求：组件就位 + 在 Splash / 登录页 / 一处加载态 先替换以验证品牌感。完整替换留到 Phase 2 收尾做一次集中 PR。

---

## 7. 测试

### 7.1 Widget 测试

新建 [frontend/test/screens/splash_screen_test.dart](../frontend/test/screens/splash_screen_test.dart)：

- **测试 1**：auth 状态为 `authenticated` 的 mock 环境下，pumpWidget Splash 后 `pump(Duration(ms: 1600))`，断言 `GoRouter.location == '/record'`。
- **测试 2**：auth 状态为 `unauthenticated`，`pump(Duration(ms: 1600))` 后路由到 `/login`。
- **测试 3**：auth 一直是 `unknown`，`pump(Duration(seconds: 5))`，路由应仍在 `/splash`；断言 `_idle` controller 循环次数 ≥ 1。
- **测试 4**：intro 阶段（t = 200ms）logo opacity ∈ (0, 1)，title opacity = 0；intro 末（t = 900ms）两者均 ≈ 1。

新建 [frontend/test/widgets/brand_mark_test.dart](../frontend/test/widgets/brand_mark_test.dart)：

- 默认色为 `AppTheme.primaryColor`；传 `color: Colors.black` 时 `colorFilter` 正确传入。

新建 [frontend/test/widgets/brand_pulse_test.dart](../frontend/test/widgets/brand_pulse_test.dart)：

- pumpWidget 后 2 秒内 Opacity.opacity 在 (0.5, 1.0) 之间往复变化，至少经历一个极值。

### 7.2 黑盒 / 真机

1. **冷启动无白屏**：Android / iOS 真机分别冷启一次，录屏检查：从点击 icon 到 Splash 可见，全程背景色 `#FFF8F5`，没有白屏帧。
2. **登录页 logo 轻摆**：进入 /login 后观察 logo 每 4s 触发一次摆动。
3. **长等 auth**：断网情况下启动（auth 必然 unknown 一段时间），Splash 持续呼吸，不早退到 `/login`。
4. **设计稿对齐**：按设计师给的标注截图对比（logo 主尺寸 140px，与屏底距离 260px，居中等）。

---

## 8. 落地步骤（推荐顺序）

1. 把素材目录建起来，先用临时占位（把 `login_screen.dart` 里的 `Icons.pets` 导出一张 svg 作占位，保证代码能跑）→ `flutter pub add flutter_svg` → `pubspec.yaml assets` 追加 `assets/brand/`。
2. 新建 `BrandMark` + `BrandPulse` widget，写对应 widget test 跑通。
3. 新建 `SplashScreen`（先用占位 logo），改 router：`initialLocation: '/splash'` + `redirect` 改造 + 挂 `/splash` 路由，真机跑一遍能从 Splash 自然跳 /login 与 /record。
4. 改 `login_screen.dart` 用 `_LoginLogo`（用占位 SVG），确认轻摆动画生效。
5. 改 Android `launch_background.xml` + `colors.xml`；iOS 打开 Xcode 改 LaunchScreen 背景色（或脚本改 storyboard 文件）；真机冷启确认无白屏。
6. 等设计师提交正式素材 → 替换占位 SVG → 回归 Widget 测试 + 真机截图对比。
7. 在 `record_screen.dart` 的两处 `CircularProgressIndicator` 换成 `BrandPulse`，作为"品牌化加载态"的样板。
8. commit：建议拆成 `chore: brand assets`（素材+pubspec）、`feat: splash screen`（含路由）、`feat: brand logo on login/appbar/loading`（复用）三个提交。

---

## 9. Out of Scope

> 明确不做，若被提及请驳回：

- **Rive 交互动画**：例如"用户点 logo 触发猫咪舔爪子"之类，留给 Phase 3。
- **深色模式 Logo**：暂时所有 Logo 基于 light 主题一套素材；深色主题整体 Phase 3 统一做。
- **Android adaptive icon 完整适配**：本步骤只管冷启动背景色；launcher icon（`ic_launcher`）完整替换放到发版前单独 PR。
- **品牌 Loading 覆盖全站**：本步骤只示范 1-2 处 `BrandPulse` 替换，完整替换留到 Phase 2 集成收尾。
- **Lottie / Rive 支持**：不引入这两个包，包体积零增长是本步骤硬约束。
- **Splash 展示营销文案 / 版本号**：可能会分散注意力，且影响首屏跳转时间；不做。

---

## 10. 主要取舍

- **不用原生 Splash 图放 Logo**：Flutter 引擎拉起前的原生屏用静态图常见，但会造成"原生屏 Logo 位置 vs Flutter Splash Logo 位置"抖一下的视觉 bug，除非两者严格对齐；对齐成本高于收益，这里只同色不同位。
- **不引 Lottie**：Logo 动画只有缩放 + 呼吸 + 轻摆三种最简模式，内置 Tween 完全够用；引入 Lottie 意味着多一个 runtime 解析开销和 150KB+ 包体积，且未来不同平台兼容性坑多。
- **Splash 最短 600ms + auth 就绪即走**：不搞固定 2-3s 等待，对老用户来说 auth 一般在 200ms 内就就绪，让他们等 2 秒是不尊重；而新设备 / 弱网可能几秒才拿到 token，这时让 Splash 呼吸等待比直接闪 `/login` 再跳 `/record` 要柔和得多。
- **单独 `BrandPulse` 组件**：看起来只是 `CircularProgressIndicator` 的替代，但集中在一个组件里维护动画节奏，未来整站品牌化替换只需改一个文件。
