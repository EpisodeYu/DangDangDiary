import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../config/theme.dart';
import '../../models/health.dart';
import '../../providers/health_provider.dart';

class DewormingRecordScreen extends ConsumerStatefulWidget {
  final int petId;
  final int? dewormingId;
  final DewormingTypeE? initialType;
  final String? initialDate;

  const DewormingRecordScreen({
    super.key,
    required this.petId,
    this.dewormingId,
    this.initialType,
    this.initialDate,
  });

  @override
  ConsumerState<DewormingRecordScreen> createState() => _DewormingRecordScreenState();
}

class _DewormingRecordScreenState extends ConsumerState<DewormingRecordScreen> {
  final _dateFormat = DateFormat('yyyy-MM-dd');
  DateTime _selectedDate = DateTime.now();
  DewormingTypeE _type = DewormingTypeE.internal;
  bool _submitting = false;

  bool get _isEditing => widget.dewormingId != null;

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
    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑驱虫记录' : '记录驱虫'),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('驱虫类型',
                  style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: DewormingTypeE.values.map((t) {
                  final selected = t == _type;
                  return ChoiceChip(
                    label: Text(t.label),
                    selected: selected,
                    onSelected: (_) => setState(() => _type = t),
                    selectedColor: AppTheme.primaryColor,
                    labelStyle: TextStyle(
                      color: selected ? Colors.white : AppTheme.textPrimary,
                      fontWeight: FontWeight.w600,
                    ),
                    backgroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide(
                        color: selected ? AppTheme.primaryColor : Colors.grey.shade300,
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 24),
              const Text('驱虫日期',
                  style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
              const SizedBox(height: 8),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: Row(
                    children: [
                      Text(_dateFormat.format(_selectedDate),
                          style: const TextStyle(fontSize: 15)),
                      const Spacer(),
                      const Icon(Icons.calendar_today, size: 18, color: AppTheme.textSecondary),
                    ],
                  ),
                ),
              ),
              const Spacer(),
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
                      : const Text('确认记录',
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
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
        await service.updateDeworming(
          widget.dewormingId!,
          dewormingType: _type,
          dewormedAt: dateStr,
        );
      } else {
        await service.createDeworming(
          widget.petId,
          dewormingType: _type,
          dewormedAt: dateStr,
        );
      }
      ref.invalidate(dewormingListProvider(widget.petId));
      ref.invalidate(dewormingStatusProvider(widget.petId));
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
