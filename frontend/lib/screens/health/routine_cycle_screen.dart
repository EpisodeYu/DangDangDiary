import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../models/health.dart';
import '../../models/pet.dart';
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
  final _controllers = <String, TextEditingController>{};
  final _enabled = <String, bool>{};
  bool _submitting = false;

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(routineStatusProvider(widget.petId));
    final pet = ref
        .watch(petListProvider)
        .valueOrNull
        ?.pets
        .where((p) => p.id == widget.petId)
        .firstOrNull;
    final editable = pet != null && pet.role != PetRole.viewer && !_submitting;
    return Scaffold(
      appBar: AppBar(title: const Text('设置日常周期与提醒')),
      body: SafeArea(
        child: state.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: TextButton(
              onPressed: () =>
                  ref.invalidate(routineStatusProvider(widget.petId)),
              child: const Text('事项加载失败，点击重试'),
            ),
          ),
          data: (status) => ListView(
            padding: const EdgeInsets.all(20),
            children: [
              for (final item in status.items) ...[
                _section(item, editable),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: editable ? () => _submit(status.items) : null,
                child: Text(_submitting ? '保存中…' : '保存设置'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _section(RoutineItem item, bool editable) {
    final key = item.type.apiValue;
    final controller = _controllers.putIfAbsent(
      key,
      () =>
          TextEditingController(text: item.status.cycleDays?.toString() ?? ''),
    );
    _enabled.putIfAbsent(key, () => item.status.reminderEnabled);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderColor),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  item.type.label,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Switch(
                value: _enabled[key]!,
                onChanged: editable
                    ? (value) => setState(() => _enabled[key] = value)
                    : null,
              ),
            ],
          ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('周期：'),
              SizedBox(
                width: 110,
                child: TextField(
                  controller: controller,
                  enabled: editable,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    hintText: '未设置',
                    isDense: true,
                  ),
                ),
              ),
              const Text('天 (1-365)'),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _submit(List<RoutineItem> items) async {
    final updates = <Map<String, dynamic>>[];
    for (final item in items) {
      final key = item.type.apiValue;
      final raw = _controllers[key]!.text.trim();
      final days = int.tryParse(raw);
      if (raw.isNotEmpty && (days == null || days < 1 || days > 365)) {
        _show('${item.type.label}周期须为 1–365 天，或留空');
        return;
      }
      updates.add({
        'routine_type': key,
        'cycle_days': days,
        'reminder_enabled': _enabled[key],
      });
    }
    setState(() => _submitting = true);
    try {
      await ref
          .read(healthServiceProvider)
          .saveRoutineItems(widget.petId, updates);
      ref.invalidate(routineStatusProvider(widget.petId));
      await ref.read(petListProvider.notifier).refresh();
      unawaited(ref.read(healthReminderSchedulerProvider).refresh());
      if (mounted) {
        _show('已保存');
        context.pop();
      }
    } catch (e) {
      final data = e is DioException ? e.response?.data : null;
      if (mounted) {
        _show(
          data is Map && data['message'] is String
              ? data['message'] as String
              : '保存失败，请重试',
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _show(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));
}
