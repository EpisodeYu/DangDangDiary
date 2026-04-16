import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';

import '../../config/theme.dart';
import '../../models/photo.dart';
import '../../providers/pet_provider.dart';
import '../../services/photo_service.dart';
import '../../utils/exif_helper.dart';
import '../../widgets/pet_selector.dart';
import '../../widgets/photo_picker_grid.dart';

final _photoServiceProvider = Provider<PhotoService>((ref) => PhotoService());

class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> {
  final List<File> _selectedFiles = [];
  DateTime _takenAt = DateTime.now();
  bool _isDateManuallyEdited = false;
  bool _isUploading = false;
  double _uploadProgress = 0;
  Map<int, String> _failureMessages = {};

  final _picker = ImagePicker();
  final _dateFormat = DateFormat('yyyy-MM-dd');

  @override
  Widget build(BuildContext context) {
    final petListAsync = ref.watch(petListProvider);
    final selectedPet = ref.watch(selectedPetProvider);
    final pets = petListAsync.valueOrNull?.pets ?? [];

    return Scaffold(
      appBar: AppBar(
        title: PetSelector(
          pets: pets,
          selectedPet: selectedPet,
          onSingleChanged: (pet) {
            if (pet != null) {
              ref.read(selectedPetIdProvider.notifier).select(pet.id);
            }
          },
        ),
      ),
      body: _buildBody(selectedPet, pets.isEmpty),
    );
  }

  Widget _buildBody(dynamic selectedPet, bool noPets) {
    if (noPets) {
      return _buildEmptyState();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSectionLabel('选择照片'),
          const SizedBox(height: 8),
          PhotoPickerGrid(
            selectedFiles: _selectedFiles,
            failureMessages: _failureMessages,
            enabled: !_isUploading,
            onAddTap: _showAddPhotoOptions,
            onRemoveTap: _removePhoto,
          ),
          const SizedBox(height: 24),
          _buildSectionLabel('拍摄日期'),
          const SizedBox(height: 8),
          _buildDatePicker(),
          const SizedBox(height: 32),
          _buildSubmitButton(),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.pets, size: 64, color: Colors.grey.shade400),
          const SizedBox(height: 16),
          const Text('请先创建宠物档案', style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => context.push('/profile/pets/new'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('去创建'),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionLabel(String text) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: AppTheme.textPrimary,
      ),
    );
  }

  Widget _buildDatePicker() {
    return GestureDetector(
      onTap: _isUploading ? null : _pickDate,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _dateFormat.format(_takenAt),
                style: const TextStyle(fontSize: 16, color: AppTheme.textPrimary),
              ),
            ),
            const Icon(Icons.calendar_today, color: AppTheme.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _buildSubmitButton() {
    final canSubmit = _selectedFiles.isNotEmpty && !_isUploading;
    return SizedBox(
      height: 50,
      child: ElevatedButton(
        onPressed: canSubmit ? _submit : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primaryColor,
          foregroundColor: Colors.white,
          disabledBackgroundColor: Colors.grey.shade300,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: const Text('记录完成', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
      ),
    );
  }

  // --- Actions ---

  void _showAddPhotoOptions() {
    final remaining = 5 - _selectedFiles.length;
    if (remaining <= 0) return;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('从相册选择'),
              onTap: () {
                Navigator.pop(ctx);
                _pickFromGallery(remaining);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('拍照'),
              onTap: () {
                Navigator.pop(ctx);
                _takePhoto();
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('取消'),
              onTap: () => Navigator.pop(ctx),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickFromGallery(int remaining) async {
    final picked = await _picker.pickMultiImage(limit: remaining);
    if (picked.isEmpty) return;

    final files = <File>[];
    for (final xfile in picked) {
      final converted = await _ensureJpeg(xfile);
      files.add(converted);
    }

    final actualToAdd = files.take(5 - _selectedFiles.length).toList();
    if (actualToAdd.isEmpty) return;

    setState(() {
      _selectedFiles.addAll(actualToAdd);
      _failureMessages = {};
    });
    await _autoFillDate();
  }

  Future<void> _takePhoto() async {
    final xfile = await _picker.pickImage(source: ImageSource.camera);
    if (xfile == null) return;

    final converted = await _ensureJpeg(xfile);

    if (_selectedFiles.length >= 5) return;
    setState(() {
      _selectedFiles.add(converted);
      _failureMessages = {};
    });
    await _autoFillDate();
  }

  Future<File> _ensureJpeg(XFile xfile) async {
    final path = xfile.path.toLowerCase();
    if (path.endsWith('.heic') || path.endsWith('.heif')) {
      final dir = await getTemporaryDirectory();
      final outPath = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
      final result = await FlutterImageCompress.compressAndGetFile(
        xfile.path,
        outPath,
        format: CompressFormat.jpeg,
        quality: 90,
      );
      if (result != null) return File(result.path);
    }
    return File(xfile.path);
  }

  void _removePhoto(int index) {
    setState(() {
      _selectedFiles.removeAt(index);
      _failureMessages = {};
      if (_selectedFiles.isEmpty) {
        _isDateManuallyEdited = false;
        _takenAt = DateTime.now();
      }
    });
  }

  Future<void> _autoFillDate() async {
    if (_isDateManuallyEdited) return;
    final exifDate = await ExifHelper.extractFirstValidDate(_selectedFiles);
    if (!mounted) return;
    setState(() {
      _takenAt = exifDate ?? DateTime.now();
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _takenAt,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() {
        _takenAt = picked;
        _isDateManuallyEdited = true;
      });
    }
  }

  Future<void> _submit() async {
    final selectedPet = ref.read(selectedPetProvider);
    if (selectedPet == null || _selectedFiles.isEmpty) return;

    setState(() {
      _isUploading = true;
      _uploadProgress = 0;
      _failureMessages = {};
    });

    _showUploadDialog();

    try {
      final service = ref.read(_photoServiceProvider);
      final response = await service.uploadPhotos(
        petId: selectedPet.id,
        files: _selectedFiles,
        takenAt: _dateFormat.format(_takenAt),
        onSendProgress: (sent, total) {
          if (mounted && total > 0) {
            setState(() => _uploadProgress = sent / total);
          }
        },
      );

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      _handleUploadResult(response);
    } on DioException catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      final data = e.response?.data;
      String message = '上传失败，请稍后重试';
      if (data is Map<String, dynamic>) {
        message = (data['message'] as String?) ?? message;
      }
      _showSnack(message);
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      _showSnack('上传失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() => _isUploading = false);
      }
    }
  }

  void _showUploadDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('正在上传照片...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: _uploadProgress),
                  const SizedBox(height: 8),
                  Text(
                    '${(_uploadProgress * 100).toInt()}%',
                    style: const TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '共 ${_selectedFiles.length} 张，请勿关闭页面',
                    style: const TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  void _handleUploadResult(PhotoUploadResponse response) {
    if (response.failureCount == 0) {
      _showSnack('记录完成，已上传 ${response.successCount} 张照片');
      setState(() {
        _selectedFiles.clear();
        _failureMessages = {};
        _takenAt = DateTime.now();
        _isDateManuallyEdited = false;
      });
    } else if (response.successCount > 0) {
      _showSnack('已成功上传 ${response.successCount} 张，失败 ${response.failureCount} 张');

      final successIndices = response.successes.map((s) => s.index).toSet();
      final newFiles = <File>[];
      final newFailures = <int, String>{};

      int newIdx = 0;
      for (int i = 0; i < _selectedFiles.length; i++) {
        if (!successIndices.contains(i)) {
          newFiles.add(_selectedFiles[i]);
          final failure = response.failures.where((f) => f.index == i).firstOrNull;
          if (failure != null) {
            newFailures[newIdx] = failure.message;
          }
          newIdx++;
        }
      }

      setState(() {
        _selectedFiles.clear();
        _selectedFiles.addAll(newFiles);
        _failureMessages = newFailures;
      });
    } else {
      _showSnack('本次未成功上传，请检查失败原因后重试');

      final failures = <int, String>{};
      for (final f in response.failures) {
        if (f.index < _selectedFiles.length) {
          failures[f.index] = f.message;
        }
      }
      setState(() => _failureMessages = failures);
    }
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
  }
}
