import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../services/pet_export_service.dart';

class PetExportDialog extends StatefulWidget {
  const PetExportDialog({
    super.key,
    required this.petId,
    required this.service,
  });
  final int petId;
  final PetExportService service;

  @override
  State<PetExportDialog> createState() => _PetExportDialogState();
}

class _PetExportDialogState extends State<PetExportDialog> {
  bool _photos = true;
  bool _records = true;
  bool _busy = false;
  bool _cancelling = false;
  String? _error;
  CancelToken? _cancelToken;
  PetExportProgress _progress = const PetExportProgress(PetExportStage.loading);

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  Future<void> _download() async {
    final token = CancelToken();
    setState(() {
      _busy = true;
      _error = null;
      _cancelToken = token;
      _progress = const PetExportProgress(PetExportStage.loading);
    });
    try {
      final saved = await widget.service.export(
        petId: widget.petId,
        photos: _photos,
        records: _records,
        cancelToken: token,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
      if (mounted) Navigator.of(context).pop(saved);
    } catch (error) {
      if (!mounted) return;
      if (token.isCancelled) {
        Navigator.of(context).pop(false);
      } else {
        setState(() {
          _busy = false;
          _error = '下载失败，请检查网络和可用空间后重试。';
        });
      }
    }
  }

  String get _status {
    if (_cancelling) return '正在取消…';
    return switch (_progress.stage) {
      PetExportStage.loading => '正在读取档案数据…',
      PetExportStage.photos =>
        '正在准备原图 ${_progress.completed}/${_progress.total}',
      PetExportStage.packing => '正在打包…',
      PetExportStage.saving => '请选择保存位置…',
    };
  }

  void _cancel() {
    if (!_busy) {
      Navigator.of(context).pop(false);
      return;
    }
    setState(() => _cancelling = true);
    _cancelToken?.cancel();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && _progress.stage != PetExportStage.saving) _cancel();
    },
    child: AlertDialog(
      title: const Text('下载此档案全部数据'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('照片'),
              value: _photos,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _photos = value!),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('记录'),
              value: _records,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _records = value!),
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value:
                    _progress.stage == PetExportStage.photos &&
                        _progress.total > 0
                    ? _progress.completed / _progress.total
                    : null,
              ),
              const SizedBox(height: 12),
              Text(_status),
            ],
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed:
              _cancelling || (_busy && _progress.stage == PetExportStage.saving)
              ? null
              : _cancel,
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy || (!_photos && !_records) ? null : _download,
          child: const Text('下载'),
        ),
      ],
    ),
  );
}
