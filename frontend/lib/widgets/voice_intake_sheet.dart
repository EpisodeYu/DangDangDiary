import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../config/theme.dart';
import '../models/health.dart';
import '../models/pet.dart';
import '../models/voice_intake.dart';
import '../services/voice_service.dart';

/// Modal bottom sheet that lets the user review/edit the LLM-produced
/// draft and confirms it to the real write service.
///
/// Responsibilities:
///
/// * Render the correct form for `response.intent` (deworming /
///   vaccination / weight / routine).
/// * Highlight fields in [VoiceIntakeResponse.missingFields] with a red
///   border + helper text so the user immediately sees what to fill in.
/// * Submit → `POST /voice/intake/confirm`.
/// * Cancel / swipe-to-dismiss → `DELETE /voice/intake/{requestId}` so
///   the draft row is cleaned up and the audio blob removed from MinIO.
///
/// Pops with:
///  * `VoiceIntakeConfirmResult` on success
///  * `null` on cancel (already cleaned up server-side when possible)
class VoiceIntakeSheet extends StatefulWidget {
  final VoiceIntakeResponse response;
  final List<Pet> pets;
  final VoiceService service;

  const VoiceIntakeSheet({
    super.key,
    required this.response,
    required this.pets,
    required this.service,
  });

  @override
  State<VoiceIntakeSheet> createState() => _VoiceIntakeSheetState();
}

class _VoiceIntakeSheetState extends State<VoiceIntakeSheet> {
  final _dateFormat = DateFormat('yyyy-MM-dd');
  bool _submitting = false;

  // Editable fields — initialised from the backend draft.
  int? _petId;
  late DateTime _date;

  DewormingTypeE? _dewormingType;
  final _vaccineCtl = TextEditingController();
  final _weightCtl = TextEditingController();
  RoutineTypeE? _routineType;

  Set<String> get _missing => widget.response.missingFields.toSet();
  VoiceIntent get _intent => widget.response.intent ?? VoiceIntent.unknown;
  VoiceIntakeDraft? get _draft => widget.response.draft;

  @override
  void initState() {
    super.initState();
    final draft = _draft;
    _petId = draft?.petId;
    _date = _parseDate(_intentDate(draft)) ?? DateTime.now();

    if (draft != null) {
      if (draft.dewormingType != null) {
        _dewormingType = _dewormingTypeFromApi(draft.dewormingType!);
      }
      if (draft.vaccineName != null) {
        _vaccineCtl.text = draft.vaccineName!;
      }
      if (draft.weightKg != null) {
        _weightCtl.text = draft.weightKg!.toStringAsFixed(2);
      }
      if (draft.routineType != null) {
        _routineType = _routineTypeFromApi(draft.routineType!);
      }
    }
  }

  @override
  void dispose() {
    _vaccineCtl.dispose();
    _weightCtl.dispose();
    super.dispose();
  }

  String? _intentDate(VoiceIntakeDraft? draft) {
    if (draft == null) return null;
    switch (_intent) {
      case VoiceIntent.deworming:
        return draft.dewormedAt;
      case VoiceIntent.vaccination:
        return draft.vaccinatedAt;
      case VoiceIntent.weight:
        return draft.weighedAt;
      case VoiceIntent.routine:
        return draft.routineAt;
      case VoiceIntent.unknown:
        return null;
    }
  }

  DateTime? _parseDate(String? iso) {
    if (iso == null || iso.isEmpty) return null;
    try {
      return _dateFormat.parse(iso);
    } catch (_) {
      return null;
    }
  }

  DewormingTypeE? _dewormingTypeFromApi(String v) {
    try {
      return DewormingTypeX.fromString(v);
    } catch (_) {
      return null;
    }
  }

  RoutineTypeE? _routineTypeFromApi(String v) {
    try {
      return RoutineTypeX.fromString(v);
    } catch (_) {
      return null;
    }
  }

  // --------------------------------------------------- build

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHandle(),
            const SizedBox(height: 4),
            _buildHeader(),
            const SizedBox(height: 16),
            _buildTranscriptCard(),
            const SizedBox(height: 16),
            ..._buildFormFields(),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _submitting ? null : _onCancel,
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: BorderSide(color: Colors.grey.shade300),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('取消',
                        style: TextStyle(color: AppTheme.textPrimary)),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ElevatedButton(
                    onPressed: _submitting ? null : _onConfirm,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _submitting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5,
                            ),
                          )
                        : const Text('确认记录',
                            style: TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600,
                            )),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle() {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: Colors.grey.shade300,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final label = voiceIntentLabel(_intent);
    final conf = widget.response.confidence ?? 0;
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppTheme.primaryColor.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Text(
            '语音记录 · $label',
            style: const TextStyle(
              color: AppTheme.primaryColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        const Spacer(),
        Text(
          '置信度 $conf',
          style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
      ],
    );
  }

  Widget _buildTranscriptCard() {
    final t = widget.response.transcript ?? '';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF4EE),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(
        t.isEmpty ? '（未识别到语音内容）' : '"$t"',
        style: const TextStyle(fontSize: 14, color: AppTheme.textPrimary),
      ),
    );
  }

  // ------------------------------------------------- intent-specific

  List<Widget> _buildFormFields() {
    final widgets = <Widget>[
      _buildPetPicker(),
      const SizedBox(height: 12),
      _buildDatePicker(),
    ];

    switch (_intent) {
      case VoiceIntent.deworming:
        widgets.addAll([
          const SizedBox(height: 12),
          _buildDewormingTypePicker(),
        ]);
        break;
      case VoiceIntent.vaccination:
        widgets.addAll([
          const SizedBox(height: 12),
          _buildVaccineInput(),
        ]);
        break;
      case VoiceIntent.weight:
        widgets.addAll([
          const SizedBox(height: 12),
          _buildWeightInput(),
        ]);
        break;
      case VoiceIntent.routine:
        widgets.addAll([
          const SizedBox(height: 12),
          _buildRoutineTypePicker(),
        ]);
        break;
      case VoiceIntent.unknown:
        break;
    }
    return widgets;
  }

  Widget _fieldShell({
    required String label,
    required bool missing,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        const SizedBox(height: 6),
        Container(
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: missing ? AppTheme.errorColor : Colors.grey.shade300,
              width: missing ? 1.4 : 1,
            ),
          ),
          child: child,
        ),
        if (missing) ...[
          const SizedBox(height: 4),
          Text(
            '语音中未听到，请补充',
            style: TextStyle(
              fontSize: 11,
              color: AppTheme.errorColor,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildPetPicker() {
    return _fieldShell(
      label: '宠物',
      missing: _missing.contains('pet_id') && _petId == null,
      child: InkWell(
        onTap: _pickPet,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Text(
                _petId == null
                    ? '请选择宠物'
                    : widget.pets
                        .firstWhere(
                          (p) => p.id == _petId,
                          orElse: () => widget.pets.first,
                        )
                        .name,
                style: TextStyle(
                  fontSize: 15,
                  color: _petId == null
                      ? AppTheme.textSecondary
                      : AppTheme.textPrimary,
                ),
              ),
              const Spacer(),
              Icon(Icons.arrow_drop_down_rounded, size: 18, color: Colors.grey.shade500),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDatePicker() {
    final fieldKey = _dateFieldKey();
    return _fieldShell(
      label: '日期',
      missing: fieldKey != null && _missing.contains(fieldKey),
      child: InkWell(
        onTap: _pickDate,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Text(_dateFormat.format(_date),
                  style: const TextStyle(fontSize: 15)),
              const Spacer(),
              Icon(Icons.calendar_today_rounded,
                  size: 18, color: AppTheme.textSecondary),
            ],
          ),
        ),
      ),
    );
  }

  String? _dateFieldKey() {
    switch (_intent) {
      case VoiceIntent.deworming:
        return 'dewormed_at';
      case VoiceIntent.vaccination:
        return 'vaccinated_at';
      case VoiceIntent.weight:
        return 'weighed_at';
      case VoiceIntent.routine:
        return 'routine_at';
      case VoiceIntent.unknown:
        return null;
    }
  }

  Widget _buildDewormingTypePicker() {
    return _fieldShell(
      label: '驱虫类型',
      missing: _missing.contains('deworming_type') && _dewormingType == null,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 8,
          children: DewormingTypeE.values.map((t) {
            final sel = t == _dewormingType;
            return ChoiceChip(
              label: Text(t.label),
              selected: sel,
              onSelected: (_) => setState(() => _dewormingType = t),
              selectedColor: AppTheme.primaryColor,
              labelStyle: TextStyle(
                color: sel ? Colors.white : AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: sel ? AppTheme.primaryColor : Colors.grey.shade300,
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildRoutineTypePicker() {
    return _fieldShell(
      label: '日常类型',
      missing: _missing.contains('routine_type') && _routineType == null,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Wrap(
          spacing: 8,
          children: RoutineTypeE.values.map((t) {
            final sel = t == _routineType;
            return ChoiceChip(
              label: Text(t.label),
              selected: sel,
              onSelected: (_) => setState(() => _routineType = t),
              selectedColor: AppTheme.primaryColor,
              labelStyle: TextStyle(
                color: sel ? Colors.white : AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
              ),
              backgroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(
                  color: sel ? AppTheme.primaryColor : Colors.grey.shade300,
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildVaccineInput() {
    return _fieldShell(
      label: '疫苗名称',
      missing:
          _missing.contains('vaccine_name') && _vaccineCtl.text.trim().isEmpty,
      child: TextField(
        controller: _vaccineCtl,
        decoration: const InputDecoration(
          hintText: '请输入疫苗名称，例如「狂犬疫苗」',
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildWeightInput() {
    return _fieldShell(
      label: '体重 (kg)',
      missing: _missing.contains('weight_kg') && _weightCtl.text.trim().isEmpty,
      child: TextField(
        controller: _weightCtl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
        ],
        decoration: const InputDecoration(
          hintText: '请输入体重，例如「5.2」',
          border: InputBorder.none,
          contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  // ------------------------------------------------------- actions

  Future<void> _pickPet() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: widget.pets
              .map((p) => ListTile(
                    title: Text(p.name),
                    subtitle: Text(p.petType == 'cat' ? '猫咪' : '狗狗'),
                    trailing: p.id == _petId
                        ? Icon(Icons.check_rounded,
                            color: AppTheme.primaryColor)
                        : null,
                    onTap: () => Navigator.pop(ctx, p.id),
                  ))
              .toList(),
        ),
      ),
    );
    if (picked != null) setState(() => _petId = picked);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _onCancel() async {
    // Fire and forget — the 24h MinIO lifecycle and log TTL make this
    // a nice-to-have, not load-bearing.
    unawaited(widget.service.cancel(widget.response.requestId));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _onConfirm() async {
    final validationError = _validate();
    if (validationError != null) {
      _showSnack(validationError);
      return;
    }

    setState(() => _submitting = true);
    try {
      final payload = _buildPayload();
      final result = await widget.service.confirm(
        requestId: widget.response.requestId,
        intent: _intent,
        payload: payload,
      );
      if (!mounted) return;
      Navigator.pop(context, result);
    } on DioException catch (e) {
      _showSnack(_friendlyError(e));
    } catch (_) {
      _showSnack('提交失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  String? _validate() {
    if (_petId == null) return '请选择宠物';
    switch (_intent) {
      case VoiceIntent.deworming:
        if (_dewormingType == null) return '请选择驱虫类型';
        break;
      case VoiceIntent.vaccination:
        if (_vaccineCtl.text.trim().isEmpty) return '请填写疫苗名称';
        break;
      case VoiceIntent.weight:
        final w = double.tryParse(_weightCtl.text.trim());
        if (w == null || w <= 0 || w > 200) return '请填写 0-200kg 之间的体重';
        break;
      case VoiceIntent.routine:
        if (_routineType == null) return '请选择日常类型';
        break;
      case VoiceIntent.unknown:
        return '无法识别意图，请重新录音';
    }
    return null;
  }

  Map<String, dynamic> _buildPayload() {
    final dateStr = _dateFormat.format(_date);
    switch (_intent) {
      case VoiceIntent.deworming:
        return {
          'pet_id': _petId,
          'deworming_type': _dewormingType!.apiValue,
          'dewormed_at': dateStr,
        };
      case VoiceIntent.vaccination:
        return {
          'pet_id': _petId,
          'vaccine_name': _vaccineCtl.text.trim(),
          'vaccinated_at': dateStr,
        };
      case VoiceIntent.weight:
        return {
          'pet_id': _petId,
          'weight_kg': double.parse(_weightCtl.text.trim()),
          'weighed_at': dateStr,
        };
      case VoiceIntent.routine:
        return {
          'pet_id': _petId,
          'routine_type': _routineType!.apiValue,
          'routine_at': dateStr,
        };
      case VoiceIntent.unknown:
        return {};
    }
  }

  String _friendlyError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    return '提交失败，请稍后重试';
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }
}

// ------------------ small helper so callers stay terse ------------------

Future<VoiceIntakeConfirmResult?> showVoiceIntakeSheet(
  BuildContext context, {
  required VoiceIntakeResponse response,
  required List<Pet> pets,
  required VoiceService service,
}) {
  return showModalBottomSheet<VoiceIntakeConfirmResult>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => VoiceIntakeSheet(
      response: response,
      pets: pets,
      service: service,
    ),
  );
}
