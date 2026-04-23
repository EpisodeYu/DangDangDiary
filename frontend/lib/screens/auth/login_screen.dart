import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../providers/auth_provider.dart';
import '../../config/theme.dart';
import '../../widgets/fluorescent_tag.dart';
import '../../widgets/doodle_background.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> with TickerProviderStateMixin {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  Timer? _timer;
  int _countdown = 0;
  bool _isSendingCode = false;

  late final AnimationController _staggerController;
  late final Animation<Offset> _logoSlide;
  late final Animation<Offset> _phoneSlide;
  late final Animation<Offset> _codeSlide;
  late final Animation<Offset> _buttonSlide;
  late final Animation<double> _fadeAnim;

  bool get _isPhoneValid => RegExp(r'^1[3-9]\d{9}$').hasMatch(_phoneController.text);
  bool get _isCodeValid => RegExp(r'^\d{6}$').hasMatch(_codeController.text);
  bool get _canSendCode => _isPhoneValid && _countdown == 0 && !_isSendingCode;
  bool get _canLogin => _isPhoneValid && _isCodeValid;

  @override
  void initState() {
    super.initState();
    
    _staggerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );

    _fadeAnim = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _staggerController, curve: Curves.easeIn),
    );

    _logoSlide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
      CurvedAnimation(parent: _staggerController, curve: const Interval(0.0, 0.5, curve: Curves.easeOutCubic)),
    );
    
    _phoneSlide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
      CurvedAnimation(parent: _staggerController, curve: const Interval(0.2, 0.7, curve: Curves.easeOutCubic)),
    );
    
    _codeSlide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
      CurvedAnimation(parent: _staggerController, curve: const Interval(0.4, 0.9, curve: Curves.easeOutCubic)),
    );
    
    _buttonSlide = Tween<Offset>(begin: const Offset(0, 0.5), end: Offset.zero).animate(
      CurvedAnimation(parent: _staggerController, curve: const Interval(0.6, 1.0, curve: Curves.easeOutCubic)),
    );

    _staggerController.forward();
  }

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _timer?.cancel();
    _staggerController.dispose();
    super.dispose();
  }

  void _startCountdown() {
    setState(() => _countdown = 60);
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdown <= 1) {
        timer.cancel();
        setState(() => _countdown = 0);
      } else {
        setState(() => _countdown--);
      }
    });
  }

  Future<void> _onSendCode() async {
    if (!_canSendCode) return;
    setState(() => _isSendingCode = true);

    await ref.read(authProvider.notifier).sendCode(_phoneController.text);

    final error = ref.read(authProvider).error;
    if (mounted) {
      setState(() => _isSendingCode = false);
      _startCountdown();
      _showSnack(error ?? '验证码已发送');
    }
  }

  Future<void> _onLogin() async {
    if (!_canLogin) return;
    final success = await ref.read(authProvider.notifier).login(
      _phoneController.text,
      _codeController.text,
    );
    if (!success && mounted) {
      final error = ref.read(authProvider).error;
      if (error != null) _showSnack(error);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);

    return Scaffold(
      body: DoodleBackground(
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 36),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 40),
                  // ── Logo ──
                  SlideTransition(
                    position: _logoSlide,
                    child: FadeTransition(
                      opacity: _fadeAnim,
                      child: const _LoginLogo(),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // ── Phone field ──
                  SlideTransition(
                    position: _phoneSlide,
                    child: FadeTransition(
                      opacity: _fadeAnim,
                      child: FluorescentTag(
                        color: Colors.white,
                        padding: EdgeInsets.zero,
                        child: TextField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          maxLength: 11,
                          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                          decoration: const InputDecoration(
                            labelText: '手机号',
                            hintText: '请输入手机号',
                            counterText: '',
                            prefixIcon: Icon(Icons.phone_android),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // ── Code field + send button ──
                  SlideTransition(
                    position: _codeSlide,
                    child: FadeTransition(
                      opacity: _fadeAnim,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: FluorescentTag(
                              color: Colors.white,
                              padding: EdgeInsets.zero,
                              child: TextField(
                                controller: _codeController,
                                keyboardType: TextInputType.number,
                                maxLength: 6,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                decoration: const InputDecoration(
                                  labelText: '验证码',
                                  hintText: '6位数字',
                                  counterText: '',
                                  prefixIcon: Icon(Icons.lock_outline),
                                ),
                                onChanged: (_) => setState(() {}),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          SizedBox(
                            height: 56,
                            child: FluorescentTag(
                              color: _canSendCode ? AppTheme.accentYellow : Colors.grey.shade200,
                              padding: EdgeInsets.zero,
                              child: ElevatedButton(
                                onPressed: _canSendCode ? _onSendCode : null,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: Colors.transparent,
                                  foregroundColor: AppTheme.textPrimary,
                                  shadowColor: Colors.transparent,
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                ),
                                child: _isSendingCode
                                    ? const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2))
                                    : Text(
                                        _countdown > 0
                                            ? '重新获取(${_countdown}s)'
                                            : '获取验证码',
                                      ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),

                  // ── Login button ──
                  SlideTransition(
                    position: _buttonSlide,
                    child: FadeTransition(
                      opacity: _fadeAnim,
                      child: SizedBox(
                        width: double.infinity,
                        height: 56,
                        child: FluorescentTag(
                          color: (_canLogin && !authState.isLoading) ? AppTheme.accentGreen : Colors.grey.shade300,
                          padding: EdgeInsets.zero,
                          child: ElevatedButton(
                            onPressed: (_canLogin && !authState.isLoading) ? _onLogin : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              foregroundColor: AppTheme.textPrimary,
                              shadowColor: Colors.transparent,
                            ),
                            child: authState.isLoading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: AppTheme.textPrimary))
                                : const Text('登录', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

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
        final angle = (_wobble.value - 0.5) * 0.21;
        return Transform.rotate(
          angle: angle,
          child: SvgPicture.asset(
            'assets/brand/logo.svg',
            width: 88,
            height: 88,
            colorFilter: const ColorFilter.mode(AppTheme.primaryColor, BlendMode.srcIn),
          ),
        );
      },
    );
  }
}
