import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/theme.dart';
import '../../providers/health_provider.dart';
import '../../providers/pet_provider.dart';

class DewormingCycleScreen extends ConsumerStatefulWidget {
  final int petId;

  const DewormingCycleScreen({super.key, required this.petId});

  @override
  ConsumerState<DewormingCycleScreen> createState() => _DewormingCycleScreenState();
}

class _DewormingCycleScreenState extends ConsumerState<DewormingCycleScreen> {
  final _internalCtl = TextEditingController();
  final _externalCtl = TextEditingController();
  final _combinedCtl = TextEditingController();

  bool _internalReminder = false;
  bool _externalReminder = false;
  bool _combinedReminder = false;

  bool _initialized = false;
  bool _submitting = false;

  @override
  void dispose() {
    _internalCtl.dispose();
    _externalCtl.dispose();
    _combinedCtl.dispose();
    super.dispose();
  }

  void _initFromPet() {
    if (_initialized) return;
    final pets = ref.read(petListProvider).valueOrNull?.pets ?? [];
    final pet = pets.where((p) => p.id == widget.petId).toList();
    if (pet.isEmpty) return;
    final p = pet.first;
    _internalCtl.text = p.internalDewormingCycleDays?.toString() ?? '30';
    _externalCtl.text = p.externalDewormingCycleDays?.toString() ?? '30';
    _combinedCtl.text = p.combinedDewormingCycleDays?.toString() ?? '90';
    _internalReminder = p.internalReminderEnabled;
    _externalReminder = p.externalReminderEnabled;
    _combinedReminder = p.combinedReminderEnabled;
    _initialized = true;
  }

  @override
  Widget build(BuildContext context) {
    _initFromPet();

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置驱虫周期与提醒'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _buildSection(
              title: '内驱',
              reminderEnabled: _internalReminder,
              onReminderChanged: (v) => setState(() => _internalReminder = v),
              controller: _internalCtl,
            ),
            const SizedBox(height: 12),
            _buildSection(
              title: '外驱',
              reminderEnabled: _externalReminder,
              onReminderChanged: (v) => setState(() => _externalReminder = v),
              controller: _externalCtl,
            ),
            const SizedBox(height: 12),
            _buildSection(
              title: '内外同驱',
              reminderEnabled: _combinedReminder,
              onReminderChanged: (v) => setState(() => _combinedReminder = v),
              controller: _combinedCtl,
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
    final internal = int.tryParse(_internalCtl.text.trim());
    final external = int.tryParse(_externalCtl.text.trim());
    final combined = int.tryParse(_combinedCtl.text.trim());

    for (final v in [internal, external, combined]) {
      if (v != null && (v < 1 || v > 365)) {
        _showSnack('驱虫周期必须在 1-365 天之间');
        return;
      }
    }

    setState(() => _submitting = true);
    try {
      final service = ref.read(healthServiceProvider);
      await service.updateDewormingCycle(
        widget.petId,
        internalCycleDays: internal,
        externalCycleDays: external,
        combinedCycleDays: combined,
        internalReminderEnabled: _internalReminder,
        externalReminderEnabled: _externalReminder,
        combinedReminderEnabled: _combinedReminder,
      );
      ref.invalidate(dewormingStatusProvider(widget.petId));
      await ref.read(petListProvider.notifier).refresh();
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
