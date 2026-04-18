import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../providers/health_provider.dart';
import '../../providers/notification_provider.dart';
import '../../providers/pet_provider.dart';

class RoutineCycleScreen extends ConsumerStatefulWidget {
  final int petId;

  const RoutineCycleScreen({super.key, required this.petId});

  @override
  ConsumerState<RoutineCycleScreen> createState() => _RoutineCycleScreenState();
}

class _RoutineCycleScreenState extends ConsumerState<RoutineCycleScreen> {
  final _bathCtl = TextEditingController();
  final _nailTrimCtl = TextEditingController();
  final _groomingCtl = TextEditingController();

  bool _bathReminder = false;
  bool _nailTrimReminder = false;
  bool _groomingReminder = false;

  bool _initialized = false;
  bool _submitting = false;

  @override
  void dispose() {
    _bathCtl.dispose();
    _nailTrimCtl.dispose();
    _groomingCtl.dispose();
    super.dispose();
  }

  void _initFromPet() {
    if (_initialized) return;
    final pets = ref.read(petListProvider).valueOrNull?.pets ?? [];
    final pet = pets.where((p) => p.id == widget.petId).toList();
    if (pet.isEmpty) return;
    final p = pet.first;
    _bathCtl.text = p.bathCycleDays?.toString() ?? '14';
    _nailTrimCtl.text = p.nailTrimCycleDays?.toString() ?? '30';
    _groomingCtl.text = p.groomingCycleDays?.toString() ?? '7';
    _bathReminder = p.bathReminderEnabled;
    _nailTrimReminder = p.nailTrimReminderEnabled;
    _groomingReminder = p.groomingReminderEnabled;
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) {
    _initFromPet();

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置日常周期与提醒'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _buildSection(
              title: '洗澡',
              reminderEnabled: _bathReminder,
              onReminderChanged: (v) => setState(() => _bathReminder = v),
              controller: _bathCtl,
            ),
            const SizedBox(height: 12),
            _buildSection(
              title: '剪指甲',
              reminderEnabled: _nailTrimReminder,
              onReminderChanged: (v) => setState(() => _nailTrimReminder = v),
              controller: _nailTrimCtl,
            ),
            const SizedBox(height: 12),
            _buildSection(
              title: '梳毛',
              reminderEnabled: _groomingReminder,
              onReminderChanged: (v) => setState(() => _groomingReminder = v),
              controller: _groomingCtl,
            ),
            const SizedBox(height: 32),
            SizedBox(
              height: 50,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.5))
                    : const Text('保存设置',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSection({
    required String title,
    required bool reminderEnabled,
    required ValueChanged<bool> onReminderChanged,
    required TextEditingController controller,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Text(title,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  )),
              const Spacer(),
              Switch(
                value: reminderEnabled,
                onChanged: onReminderChanged,
                activeThumbColor: AppTheme.primaryColor,
              ),
            ],
          ),
          Row(
            children: [
              const Text('周期：',
                  style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
              SizedBox(
                width: 80,
                child: TextField(
                  controller: controller,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(left: 8),
                child: Text('天 (1-365)',
                    style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submit() async {
    final bath = int.tryParse(_bathCtl.text.trim());
    final nailTrim = int.tryParse(_nailTrimCtl.text.trim());
    final grooming = int.tryParse(_groomingCtl.text.trim());

    for (final v in [bath, nailTrim, grooming]) {
      if (v != null && (v < 1 || v > 365)) {
        _showSnack('日常周期必须在 1-365 天之间');
        return;
      }
    }

    setState(() => _submitting = true);
    try {
      final service = ref.read(healthServiceProvider);
      await service.updateRoutineCycle(
        widget.petId,
        bathCycleDays: bath,
        nailTrimCycleDays: nailTrim,
        groomingCycleDays: grooming,
        bathReminderEnabled: _bathReminder,
        nailTrimReminderEnabled: _nailTrimReminder,
        groomingReminderEnabled: _groomingReminder,
      );
      ref.invalidate(routineStatusProvider(widget.petId));
      await ref.read(petListProvider.notifier).refresh();
      unawaited(ref.read(healthReminderSchedulerProvider).refresh());
      if (mounted) {
        _showSnack('已保存');
        context.pop();
      }
    } on DioException catch (e) {
      _showSnack(_friendlyError(e));
    } catch (_) {
      _showSnack('保存失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String _friendlyError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return '保存失败，请稍后重试';
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }
}
