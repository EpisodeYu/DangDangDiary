import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../config/theme.dart';
import '../../providers/health_provider.dart';
import '../../providers/pet_provider.dart';

class VaccinationRecordScreen extends ConsumerStatefulWidget {
  final int petId;
  final int? vaccinationId;
  final String? initialType;
  final String? initialDate;

  const VaccinationRecordScreen({
    super.key,
    required this.petId,
    this.vaccinationId,
    this.initialType,
    this.initialDate,
  });

  @override
  ConsumerState<VaccinationRecordScreen> createState() => _VaccinationRecordScreenState();
}

class _VaccinationRecordScreenState extends ConsumerState<VaccinationRecordScreen> {
  final _typeCtl = TextEditingController();
  final _dateFormat = DateFormat('yyyy-MM-dd');
  DateTime _selectedDate = DateTime.now();
  bool _submitting = false;

  bool get _isEditing => widget.vaccinationId != null;

  @override
  void initState() {
    super.initState();
    if (widget.initialType != null) {
      _typeCtl.text = widget.initialType!;
    }
    if (widget.initialDate != null && widget.initialDate!.isNotEmpty) {
      try {
        _selectedDate = _dateFormat.parse(widget.initialDate!);
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _typeCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pets = ref.watch(petListProvider).valueOrNull?.pets ?? [];
    final pet = pets.where((p) => p.id == widget.petId).toList();
    final petType = pet.isEmpty ? 'cat' : pet.first.petType;
    final presetsAsync = ref.watch(vaccineTypesProvider(petType));

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑疫苗记录' : '记录疫苗'),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('疫苗类型',
                style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
            const SizedBox(height: 8),
            TextField(
              controller: _typeCtl,
              decoration: InputDecoration(
                hintText: '请选择或输入疫苗类型',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: Colors.grey.shade300),
                ),
              ),
            ),
            const SizedBox(height: 12),
            presetsAsync.when(
              loading: () => const SizedBox(
                height: 32,
                child: Center(child: SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2))),
              ),
              error: (_, _) => const SizedBox.shrink(),
              data: (presets) => Wrap(
                spacing: 8,
                runSpacing: 8,
                children: presets.map((p) {
                  return ActionChip(
                    label: Text(p),
                    backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                    labelStyle: const TextStyle(
                      color: AppTheme.primaryColor,
                      fontWeight: FontWeight.w600,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                      side: BorderSide.none,
                    ),
                    onPressed: () {
                      setState(() {
                        _typeCtl.text = p;
                      });
                    },
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 24),
            const Text('接种日期',
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
                    Icon(Icons.calendar_today_rounded, size: 18, color: AppTheme.textSecondary),
                  ],
                ),
              ),
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
                    : const Text('确认记录',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
    final typeText = _typeCtl.text.trim();
    if (typeText.isEmpty) {
      _showSnack('请输入或选择疫苗类型');
      return;
    }
    if (typeText.length > 100) {
      _showSnack('疫苗类型长度不能超过 100 个字符');
      return;
    }

    setState(() => _submitting = true);
    try {
      final service = ref.read(healthServiceProvider);
      final dateStr = _dateFormat.format(_selectedDate);
      if (_isEditing) {
        await service.updateVaccination(
          widget.vaccinationId!,
          vaccineType: typeText,
          vaccinatedAt: dateStr,
        );
      } else {
        await service.createVaccination(
          widget.petId,
          vaccineType: typeText,
          vaccinatedAt: dateStr,
        );
      }
      ref.invalidate(vaccinationListProvider(widget.petId));
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
