import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../config/theme.dart';
import '../../widgets/app_form_body.dart';

import '../../models/health.dart';
import '../../providers/health_provider.dart';
import '../../providers/notification_provider.dart';
import '../../providers/pet_provider.dart';
import '../../models/pet.dart';

class RoutineRecordScreen extends ConsumerStatefulWidget {
  final int petId;
  final int? routineId;
  final RoutineTypeE? initialType;
  final String? initialDate;

  const RoutineRecordScreen({
    super.key,
    required this.petId,
    this.routineId,
    this.initialType,
    this.initialDate,
  });

  @override
  ConsumerState<RoutineRecordScreen> createState() =>
      _RoutineRecordScreenState();
}

class _RoutineRecordScreenState extends ConsumerState<RoutineRecordScreen> {
  final _dateFormat = DateFormat('yyyy-MM-dd');
  DateTime _selectedDate = DateTime.now();
  RoutineTypeE _type = RoutineTypeE.bath;
  bool _submitting = false;

  bool get _isEditing => widget.routineId != null;

  @override
  void initState() {
    super.initState();
    if (widget.initialType != null) {
      _type = widget.initialType!;
    }
    if (widget.initialDate != null && widget.initialDate!.isNotEmpty) {
      try {
        _selectedDate = _dateFormat.parse(widget.initialDate!);
      } catch (_) {}
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(routineStatusProvider(widget.petId));
    final pet = ref
        .watch(petListProvider)
        .valueOrNull
        ?.pets
        .where((p) => p.id == widget.petId)
        .firstOrNull;
    final canEdit = pet != null && pet.role != PetRole.viewer;
    final types =
        status.valueOrNull?.items.map((i) => i.type).toList() ??
        <RoutineTypeE>[];
    if (_isEditing &&
        widget.initialType != null &&
        !types.contains(widget.initialType)) {
      types.add(widget.initialType!);
    }
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? '编辑日常记录' : '记录日常')),
      body: status.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: TextButton(
            onPressed: () =>
                ref.invalidate(routineStatusProvider(widget.petId)),
            child: const Text('事项加载失败，点击重试'),
          ),
        ),
        data: (_) => AppFormBody(
          title: '照顾好每一天',
          subtitle: '选择事项，记录完成日期。',
          icon: Icons.spa_rounded,
          action: SizedBox(
            height: 50,
            child: ElevatedButton(
              onPressed: _submitting || !canEdit ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primaryColor,
                foregroundColor: AppTheme.primaryInk,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: _submitting
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.5,
                      ),
                    )
                  : const Text(
                      '确认记录',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          children: [
            const Text(
              '日常类型',
              style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: types.map((t) {
                final selected = t == _type;
                return ChoiceChip(
                  label: Text(t.label),
                  selected: selected,
                  onSelected: !canEdit
                      ? null
                      : (_) => setState(() => _type = t),
                  selectedColor: AppTheme.softPeach,
                  labelStyle: TextStyle(
                    color: selected
                        ? AppTheme.accentColor
                        : AppTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  backgroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                    side: BorderSide(
                      color: selected
                          ? AppTheme.primaryColor
                          : AppTheme.borderColor,
                    ),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 24),
            const Text(
              '日常日期',
              style: TextStyle(fontSize: 14, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: canEdit && !_submitting ? _pickDate : null,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 16,
                ),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: AppTheme.borderColor),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        _dateFormat.format(_selectedDate),
                        style: const TextStyle(fontSize: 15),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      Icons.calendar_today_rounded,
                      size: 18,
                      color: AppTheme.textSecondary,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  Future<void> _submit() async {
    setState(() => _submitting = true);
    try {
      final service = ref.read(healthServiceProvider);
      final dateStr = _dateFormat.format(_selectedDate);
      if (_isEditing) {
        await service.updateRoutine(
          widget.routineId!,
          routineType: _type,
          performedAt: dateStr,
        );
      } else {
        await service.createRoutine(
          widget.petId,
          routineType: _type,
          performedAt: dateStr,
        );
      }
      ref.invalidate(routineListProvider(widget.petId));
      ref.invalidate(routineStatusProvider(widget.petId));
      unawaited(ref.read(healthReminderSchedulerProvider).refresh());
      if (mounted) {
        _showSnack(_isEditing ? '已更新' : '已记录');
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
