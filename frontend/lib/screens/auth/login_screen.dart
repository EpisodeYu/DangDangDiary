import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  Timer? _timer;
  int _countdown = 0;
  bool _isSendingCode = false;

  bool get _isPhoneValid => RegExp(r'^1[3-9]\d{9}$').hasMatch(_phoneController.text);
  bool get _isCodeValid => RegExp(r'^\d{6}$').hasMatch(_codeController.text);
  bool get _canSendCode => _isPhoneValid && _countdown == 0 && !_isSendingCode;
  bool get _canLogin => _isPhoneValid && _isCodeValid;

  @override
  void dispose() {
    _phoneController.dispose();
    _codeController.dispose();
    _timer?.cancel();
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
    final theme = Theme.of(context);

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 36),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 40),
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
                const SizedBox(height: 20),
                Text('当当日记',
                    style: theme.textTheme.headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('记录毛孩子的每一天',
                    style: theme.textTheme.bodyLarge?.copyWith(color: Colors.grey)),
                const SizedBox(height: 48),

                // ── Phone field ──
                TextField(
                  controller: _phoneController,
                  keyboardType: TextInputType.phone,
                  maxLength: 11,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    labelText: '手机号',
                    hintText: '请输入手机号',
                    counterText: '',
                    prefixIcon: const Icon(Icons.phone_android),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),

                // ── Code field + send button ──
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _codeController,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: InputDecoration(
                          labelText: '验证码',
                          hintText: '6位数字',
                          counterText: '',
                          prefixIcon: const Icon(Icons.lock_outline),
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    const SizedBox(width: 12),
                    SizedBox(
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _canSendCode ? _onSendCode : null,
                        style: ElevatedButton.styleFrom(
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
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
                  ],
                ),
                const SizedBox(height: 32),

                // ── Login button ──
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: (_canLogin && !authState.isLoading) ? _onLogin : null,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: authState.isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white))
                        : const Text('登录', style: TextStyle(fontSize: 16)),
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
