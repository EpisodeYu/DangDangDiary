import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

class RoutineItemDialog extends StatefulWidget {
  final String? initialName;
  final Future<void> Function(String) onSave;
  const RoutineItemDialog({super.key, this.initialName, required this.onSave});

  @override
  State<RoutineItemDialog> createState() => _RoutineItemDialogState();
}

class _RoutineItemDialogState extends State<RoutineItemDialog> {
  late final _name = TextEditingController(text: widget.initialName);
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请输入事项名称');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(name);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      final data = e is DioException ? e.response?.data : null;
      if (mounted) {
        setState(() {
          _saving = false;
          _error = data is Map && data['message'] is String
              ? data['message'] as String
              : '保存失败，请重试';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(widget.initialName == null ? '新增日常事项' : '重命名日常事项'),
      content: TextField(
        controller: _name,
        autofocus: true,
        maxLength: 20,
        enabled: !_saving,
        decoration: InputDecoration(
          labelText: '事项名称',
          hintText: '例如：刷牙',
          errorText: _error,
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    ),
  );
}
