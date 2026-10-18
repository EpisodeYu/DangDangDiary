import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../widgets/login_logo.dart';
import '../../widgets/app_card.dart';
import '../../config/theme.dart';

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

  bool get _isPhoneValid =>
      RegExp(r'^1[3-9]\d{9}$').hasMatch(_phoneController.text);
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
    final success = await ref
        .read(authProvider.notifier)
        .login(_phoneController.text, _codeController.text);
    if (!success && mounted) {
      final error = ref.read(authProvider).error;
      if (error != null) _showSnack(error);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final compact =
        MediaQuery.sizeOf(context).width < 380 ||
        MediaQuery.textScalerOf(context).scale(1) > 1.2;
    final codeField = TextField(
      controller: _codeController,
      keyboardType: TextInputType.number,
      maxLength: 6,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: const InputDecoration(
        labelText: '验证码',
        hintText: '6位数字',
        counterText: '',
        prefixIcon: Icon(Icons.lock_outline_rounded),
      ),
      onChanged: (_) => setState(() {}),
    );
    final sendButton = TextButton(
      onPressed: _canSendCode ? _onSendCode : null,
      child: _isSendingCode
          ? const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Text(_countdown > 0 ? '重新获取(${_countdown}s)' : '获取验证码'),
    );
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LoginLogo(),
                  const SizedBox(height: 20),
                  Text(
                    '当当日记',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    '记录毛孩子的每一天',
                    style: TextStyle(
                      fontSize: 15,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                  const SizedBox(height: 32),
                  AppCard(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '欢迎回家',
                          style: TextStyle(
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          '用手机号，开启相伴的日常',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 28),
                        TextField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          maxLength: 11,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: const InputDecoration(
                            labelText: '手机号',
                            hintText: '请输入手机号',
                            counterText: '',
                            prefixIcon: Icon(Icons.phone_android_rounded),
                          ),
                          onChanged: (_) => setState(() {}),
                        ),
                        const SizedBox(height: 20),
                        if (compact) ...[
                          codeField,
                          Align(
                            alignment: Alignment.centerRight,
                            child: sendButton,
                          ),
                        ] else
                          Row(
                            children: [
                              Expanded(child: codeField),
                              const SizedBox(width: 8),
                              sendButton,
                            ],
                          ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: (_canLogin && !authState.isLoading)
                              ? _onLogin
                              : null,
                          child: authState.isLoading
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : const Text('登录'),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
