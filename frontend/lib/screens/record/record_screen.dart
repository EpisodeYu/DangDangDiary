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

final _photoServiceProvider = Provider<PhotoService>((ref) => PhotoService());

class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> {
  final List<File> _selectedFiles = [];
  final List<DateTime> _photoDates = [];
  bool _isUploading = false;
  final ValueNotifier<double> _uploadProgress = ValueNotifier(0);
  Map<int, String> _failureMessages = {};

  final _picker = ImagePicker();
  final _dateFormat = DateFormat('yyyy-MM-dd');

  @override
  void dispose() {
    _uploadProgress.dispose();
    super.dispose();
  }

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

    if (_selectedFiles.isEmpty) {
      return _buildInitialState();
    }

    return _buildPhotoListState();
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

  Widget _buildInitialState() {
    return GestureDetector(
      onTap: _showAddPhotoOptions,
      child: SizedBox.expand(
        child: Container(
          color: AppTheme.secondaryColor.withValues(alpha: 0.15),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: AppTheme.secondaryColor.withValues(alpha: 0.4),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.add_a_photo_outlined, size: 36, color: AppTheme.primaryColor),
              ),
              const SizedBox(height: 16),
              const Text(
                '点击添加照片',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w500, color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                '支持从相册选择或拍照，最多5张',
                style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPhotoListState() {
    return Column(
      children: [
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
            itemCount: _selectedFiles.length + (_selectedFiles.length < 5 && !_isUploading ? 1 : 0),
            itemBuilder: (context, index) {
              if (index < _selectedFiles.length) {
                return _buildPhotoCard(index);
              }
              return _buildAddMoreButton();
            },
          ),
        ),
        _buildBottomSubmitBar(),
      ],
    );
  }

  Widget _buildPhotoCard(int index) {
    final file = _selectedFiles[index];
    final date = _photoDates[index];
    final failureMsg = _failureMessages[index];

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Photo preview with remove button
          Stack(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.file(file, fit: BoxFit.cover, cacheWidth: 600),
                ),
              ),
              if (!_isUploading)
                Positioned(
                  top: 8,
                  right: 8,
                  child: GestureDetector(
                    onTap: () => _removePhoto(index),
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.close, size: 16, color: Colors.white),
                    ),
                  ),
                ),
              if (failureMsg != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: AppTheme.errorColor.withValues(alpha: 0.85),
                    ),
                    child: Text(
                      failureMsg,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
            ],
          ),
          // Date picker row
          GestureDetector(
            onTap: _isUploading ? null : () => _pickDateForPhoto(index),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                children: [
                  const Icon(Icons.calendar_today, size: 18, color: AppTheme.textSecondary),
                  const SizedBox(width: 8),
                  Text(
                    _dateFormat.format(date),
                    style: const TextStyle(fontSize: 15, color: AppTheme.textPrimary),
                  ),
                  const Spacer(),
                  Icon(Icons.chevron_right, size: 20, color: Colors.grey.shade400),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddMoreButton() {
    return GestureDetector(
      onTap: _showAddPhotoOptions,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        height: 64,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300, width: 1.5),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.add, size: 22, color: Colors.grey.shade500),
            const SizedBox(width: 6),
            Text(
              '继续添加照片',
              style: TextStyle(fontSize: 14, color: Colors.grey.shade500),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomSubmitBar() {
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SizedBox(
        width: double.infinity,
        height: 50,
        child: ElevatedButton(
          onPressed: _isUploading ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryColor,
            foregroundColor: Colors.white,
            disabledBackgroundColor: Colors.grey.shade300,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('记录完成', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
        ),
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

    // Extract EXIF dates for each new photo
    final dates = <DateTime>[];
    for (final file in actualToAdd) {
      final exifDate = await ExifHelper.extractDate(file);
      dates.add(exifDate ?? DateTime.now());
    }

    if (!mounted) return;
    setState(() {
      _selectedFiles.addAll(actualToAdd);
      _photoDates.addAll(dates);
      _failureMessages = {};
    });
  }

  Future<void> _takePhoto() async {
    final xfile = await _picker.pickImage(source: ImageSource.camera);
    if (xfile == null) return;

    final converted = await _ensureJpeg(xfile);

    if (_selectedFiles.length >= 5) return;

    if (!mounted) return;
    setState(() {
      _selectedFiles.add(converted);
      _photoDates.add(DateTime.now());
      _failureMessages = {};
    });
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
      _photoDates.removeAt(index);
      _failureMessages = {};
    });
  }

  Future<void> _pickDateForPhoto(int index) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _photoDates[index],
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _photoDates[index] = picked);
    }
  }

  Future<void> _submit() async {
    final selectedPet = ref.read(selectedPetProvider);
    if (selectedPet == null || _selectedFiles.isEmpty) return;

    setState(() {
      _isUploading = true;
      _failureMessages = {};
    });
    _uploadProgress.value = 0;

    _showUploadDialog();

    try {
      final service = ref.read(_photoServiceProvider);
      final takenAtDates = _photoDates.map((d) => _dateFormat.format(d)).toList();
      final response = await service.uploadPhotos(
        petId: selectedPet.id,
        files: _selectedFiles,
        takenAtDates: takenAtDates,
        onSendProgress: (sent, total) {
          if (total > 0) {
            _uploadProgress.value = sent / total;
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
    final fileCount = _selectedFiles.length;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: false,
        child: ValueListenableBuilder<double>(
          valueListenable: _uploadProgress,
          builder: (ctx, progress, _) {
            return AlertDialog(
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('正在上传照片...', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 16),
                  LinearProgressIndicator(value: progress),
                  const SizedBox(height: 8),
                  Text(
                    '${(progress * 100).toInt()}%',
                    style: const TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '共 $fileCount 张，请勿关闭页面',
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
      _showSnack('上传成功，请在时间轴内查看吧！');
      setState(() {
        _selectedFiles.clear();
        _photoDates.clear();
        _failureMessages = {};
      });
    } else if (response.successCount > 0) {
      _showSnack('已成功上传 ${response.successCount} 张，失败 ${response.failureCount} 张');

      final successIndices = response.successes.map((s) => s.index).toSet();
      final newFiles = <File>[];
      final newDates = <DateTime>[];
      final newFailures = <int, String>{};

      int newIdx = 0;
      for (int i = 0; i < _selectedFiles.length; i++) {
        if (!successIndices.contains(i)) {
          newFiles.add(_selectedFiles[i]);
          newDates.add(_photoDates[i]);
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
        _photoDates.clear();
        _photoDates.addAll(newDates);
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
