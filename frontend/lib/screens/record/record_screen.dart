import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../config/theme.dart';
import '../../models/pet.dart';
import '../../models/photo.dart';
import '../../models/voice_intake.dart';
import '../../providers/health_provider.dart';
import '../../providers/pet_provider.dart';
import '../../services/classify_service.dart';
import '../../services/original_photo_cache.dart';
import '../../services/pet_classifier.dart';
import '../../services/photo_service.dart';
import '../../services/voice_service.dart';
import '../../utils/exif_helper.dart';
import '../../widgets/brand_mark.dart';
import '../../widgets/brand_pulse.dart';
import '../../widgets/pet_chip_dropdown.dart';
import '../../widgets/voice_intake_sheet.dart';
import '../../widgets/voice_record_button.dart';

final _photoServiceProvider = Provider<PhotoService>((ref) => PhotoService());
final _voiceServiceProvider = Provider<VoiceService>((ref) => VoiceService());
final _classifyServiceProvider =
    Provider<ClassifyService>((ref) => ClassifyService());

class RecordScreen extends ConsumerStatefulWidget {
  const RecordScreen({super.key});

  @override
  ConsumerState<RecordScreen> createState() => _RecordScreenState();
}

class _RecordScreenState extends ConsumerState<RecordScreen> {
  // --- Per-photo parallel lists. All of these MUST stay in lockstep;
  // any add/remove path updates every one of them at the same index.
  final List<File> _selectedFiles = [];
  final List<DateTime> _photoDates = [];
  // Each pending token points at an entry in the persistent
  // original-photo cache so the bytes are reused after upload.
  final List<String> _pendingTokens = [];
  // Phase 2 Step 3: classify chip state per photo.
  final List<int?> _assignedPetIds = [];
  final List<bool> _wasAutoAssigned = [];
  final List<bool> _isRecognizing = [];
  // True once the user has manually picked a pet for this photo. Once
  // flipped, the pending classify response for the photo is ignored so
  // that a slow model can't overwrite the user's explicit choice.
  final List<bool> _userPicked = [];
  // Option A feedback plumbing: remember what the classify endpoint
  // *originally* suggested so the upload call can forward it to the
  // server when the user overrode the chip. Parallel to
  // [_assignedPetIds] but never mutated after the classify response
  // lands. ``null`` = model offered no suggestion / request failed.
  final List<int?> _originalAssignedPetIds = [];
  final List<double?> _originalConfidences = [];

  bool _isUploading = false;
  final ValueNotifier<double> _uploadProgress = ValueNotifier(0);
  final ValueNotifier<bool> _isServerProcessing = ValueNotifier(false);
  Map<int, String> _failureMessages = {};

  // Token for the in-flight `/photos/classify` request, if any. We
  // cancel it when the user hits "记录完成" so the pending soft-guess
  // stops competing with the upload for server-side DashScope + thread
  // pool capacity (see root-cause analysis 2026-04-22). ``null`` when
  // no classify is running.
  CancelToken? _classifyCancelToken;

  // Phase 2 Step 2 — voice intake.
  bool _voiceProcessing = false;

  final _picker = ImagePicker();
  final _dateFormat = DateFormat('yyyy-MM-dd');
  final _uuid = const Uuid();

  @override
  void dispose() {
    // Abort any still-in-flight classify so we don't leak a pending
    // DashScope call after the screen is gone.
    _classifyCancelToken?.cancel('record_screen disposed');
    _classifyCancelToken = null;
    _uploadProgress.dispose();
    _isServerProcessing.dispose();
    super.dispose();
  }

  // --- Computed state ---

  /// Only pets the caller can *write* to are valid chip targets. The
  /// classify endpoint filters the same way server-side, so keeping
  /// this consistent avoids surfacing a pet whose upload would later
  /// 403.
  List<Pet> get _editableCandidatePets {
    final pets = ref.read(petListProvider).valueOrNull?.pets ?? const <Pet>[];
    return pets
        .where((p) => p.role == PetRole.owner || p.role == PetRole.editor)
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final petListAsync = ref.watch(petListProvider);
    final pets = petListAsync.valueOrNull?.pets ?? const <Pet>[];
    final editable = pets
        .where((p) => p.role == PetRole.owner || p.role == PetRole.editor)
        .toList();

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 16,
        centerTitle: true,
        leading: const Padding(
          padding: EdgeInsets.only(left: 16),
          child: Center(child: BrandMark(size: 22)),
        ),
        title: const Text(
          '记录',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppTheme.textPrimary,
          ),
        ),
      ),
      body: _buildBody(
        noPets: pets.isEmpty,
        noEditablePets: pets.isNotEmpty && editable.isEmpty,
      ),
    );
  }

  Widget _buildBody({required bool noPets, required bool noEditablePets}) {
    if (noPets) return _buildEmptyState();
    if (noEditablePets) return _buildReadonlyState();

    final Widget body;
    if (_selectedFiles.isEmpty) {
      body = _buildInitialState();
    } else {
      body = _buildPhotoListState();
    }
    return Column(
      children: [
        Expanded(child: body),
        _buildVoiceBar(),
      ],
    );
  }

  Widget _buildVoiceBar() {
    // Disabled during photo upload to avoid overlapping multipart
    // requests fighting over the progress HUD + cache bookkeeping.
    final disabled = _isUploading || _voiceProcessing;
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 12, 16, 12 + MediaQuery.of(context).padding.bottom),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Stack(
        children: [
          VoiceRecordButton(
            enabled: !disabled,
            onRecordComplete: _handleVoiceClipReady,
          ),
          if (_voiceProcessing)
            const Positioned.fill(
              child: Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2.5),
                ),
              ),
            ),
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
          const Text('请先创建宠物档案',
              style: TextStyle(fontSize: 16, color: AppTheme.textSecondary)),
          const SizedBox(height: 12),
          ElevatedButton(
            onPressed: () => context.push('/profile/pets/new'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primaryColor,
              foregroundColor: Colors.white,
              shape:
                  RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('去创建'),
          ),
        ],
      ),
    );
  }

  Widget _buildReadonlyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.visibility_outlined,
                size: 64, color: Colors.grey.shade400),
            const SizedBox(height: 16),
            const Text(
              '当前没有可编辑的宠物档案',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 16, color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 6),
            Text(
              '只能查看的档案无法上传照片，请联系档案拥有者获取编辑权限，或自行创建档案。',
              textAlign: TextAlign.center,
              style:
                  TextStyle(fontSize: 13, color: Colors.grey.shade500),
            ),
          ],
        ),
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
                child: const Icon(Icons.add_a_photo_outlined,
                    size: 36, color: AppTheme.primaryColor),
              ),
              const SizedBox(height: 16),
              const Text(
                '点击添加照片',
                style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                    color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 6),
              Text(
                '选完照片将自动识别归属的宠物，最多 5 张',
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
            itemCount: _selectedFiles.length +
                (_selectedFiles.length < 5 && !_isUploading ? 1 : 0),
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
    final pets = _editableCandidatePets;
    final assigned = _assignedPetIds[index];
    Pet? selectedPet;
    if (assigned != null) {
      for (final p in pets) {
        if (p.id == assigned) {
          selectedPet = p;
          break;
        }
      }
      // If the pet vanished (e.g. share revoked between pick + submit),
      // fall back to null so the user is nudged to pick again.
      if (selectedPet == null) {
        _assignedPetIds[index] = null;
        _wasAutoAssigned[index] = false;
        _userPicked[index] = false;
      }
    }

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
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
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
                      child:
                          const Icon(Icons.close, size: 16, color: Colors.white),
                    ),
                  ),
                ),
              if (failureMsg != null)
                Positioned(
                  bottom: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 6),
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
          // Date + pet chip row
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Row(
              children: [
                GestureDetector(
                  onTap: _isUploading ? null : () => _pickDateForPhoto(index),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.calendar_today,
                          size: 18, color: AppTheme.textSecondary),
                      const SizedBox(width: 8),
                      Text(
                        _dateFormat.format(date),
                        style: const TextStyle(
                            fontSize: 15, color: AppTheme.textPrimary),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right,
                          size: 20, color: Colors.grey.shade400),
                    ],
                  ),
                ),
                const Spacer(),
                PetChipDropdown(
                  pets: pets,
                  selected: selectedPet,
                  isRecognizing: _isRecognizing[index],
                  wasAutoAssigned: _wasAutoAssigned[index],
                  enabled: !_isUploading,
                  onChanged: (pet) {
                    setState(() {
                      _assignedPetIds[index] = pet.id;
                      _wasAutoAssigned[index] = false;
                      // User has overridden — stop the spinner and
                      // pin this choice so the in-flight classify
                      // response can't clobber it when it arrives.
                      _isRecognizing[index] = false;
                      _userPicked[index] = true;
                    });
                  },
                ),
              ],
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
      // The voice bar below us owns the safe-area padding, so we only
      // need the inner 12px breathing room here.
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('记录完成',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
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
    // image_picker's pickMultiImage requires limit >= 2; fall back to pickImage for 1.
    final List<XFile> picked;
    if (remaining == 1) {
      final one = await _picker.pickImage(source: ImageSource.gallery);
      picked = one == null ? const <XFile>[] : [one];
    } else {
      picked = await _picker.pickMultiImage(limit: remaining);
    }
    if (picked.isEmpty) return;

    // Android 13+ Photo Picker enforces the `limit` natively (see main.dart),
    // but Android <13 and some third-party pickers ignore it. Cap here as a
    // fallback and surface a gentle prompt instead of silently dropping.
    final overflowed = picked.length > remaining;
    final toProcess = overflowed ? picked.take(remaining).toList() : picked;
    if (overflowed) {
      _showSnack('每次最多上传5张哦！');
    }

    _showRecognizingDialog();

    // Read EXIF from the original file before _ensureJpeg compresses it —
    // FlutterImageCompress strips EXIF metadata, so the compressed copy has no DateTimeOriginal.
    final files = <File>[];
    final dates = <DateTime>[];
    final tokens = <String>[];
    var rejected = 0;
    for (final xfile in toProcess) {
      final exifDate = await ExifHelper.extractDate(File(xfile.path));
      // Classify on the original file — FlutterImageCompress's re-encode
      // roughly halves cat/dog softmax on marginal inputs.
      final result = await PetClassifier.instance.classify(File(xfile.path));
      if (!result.isPet && !result.skipped) {
        rejected++;
        continue;
      }
      final converted = await _ensureJpeg(xfile);
      final token = await _cachePending(converted);
      files.add(converted);
      tokens.add(token);
      dates.add(exifDate ?? DateTime.now());
    }

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (files.isEmpty) {
      if (rejected > 0) {
        _showSnack(rejected == toProcess.length
            ? '未识别到猫狗，请换一张图片试试吧！'
            : '已跳过 $rejected 张未识别到猫狗的图片');
      }
      return;
    }

    // When the caller only has a single writable pet profile (owned
    // or shared with editor rights), there is nothing to classify —
    // skip the server round-trip and bind every photo to that pet.
    final editable = _editableCandidatePets;
    final onlyPetId =
        editable.length == 1 ? editable.first.id : null;

    final baseIdx = _selectedFiles.length;
    setState(() {
      _selectedFiles.addAll(files);
      _photoDates.addAll(dates);
      _pendingTokens.addAll(tokens);
      _assignedPetIds
          .addAll(List<int?>.filled(files.length, onlyPetId));
      _wasAutoAssigned.addAll(List<bool>.filled(files.length, true));
      _isRecognizing
          .addAll(List<bool>.filled(files.length, onlyPetId == null));
      _userPicked.addAll(List<bool>.filled(files.length, false));
      _originalAssignedPetIds
          .addAll(List<int?>.filled(files.length, null));
      _originalConfidences
          .addAll(List<double?>.filled(files.length, null));
      _failureMessages = {};
    });

    if (rejected > 0) {
      _showSnack('已跳过 $rejected 张未识别到猫狗的图片');
    }

    if (onlyPetId == null) {
      _runClassifyAssignment(baseIdx: baseIdx, files: files);
    }
  }

  Future<void> _takePhoto() async {
    final xfile = await _picker.pickImage(source: ImageSource.camera);
    if (xfile == null) return;

    if (_selectedFiles.length >= 5) return;

    _showRecognizingDialog();

    final result = await PetClassifier.instance.classify(File(xfile.path));

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (!result.isPet && !result.skipped) {
      _showSnack('未识别到猫狗，请换一张图片试试吧！');
      return;
    }

    final converted = await _ensureJpeg(xfile);

    final token = await _cachePending(converted);

    // Single-profile fast path — mirror the gallery flow.
    final editable = _editableCandidatePets;
    final onlyPetId =
        editable.length == 1 ? editable.first.id : null;

    final baseIdx = _selectedFiles.length;
    setState(() {
      _selectedFiles.add(converted);
      _pendingTokens.add(token);
      _photoDates.add(DateTime.now());
      _assignedPetIds.add(onlyPetId);
      _wasAutoAssigned.add(true);
      _isRecognizing.add(onlyPetId == null);
      _userPicked.add(false);
      _originalAssignedPetIds.add(null);
      _originalConfidences.add(null);
      _failureMessages = {};
    });

    if (onlyPetId == null) {
      _runClassifyAssignment(baseIdx: baseIdx, files: [converted]);
    }
  }

  /// Fire off a classify request for the just-added photos and patch
  /// the per-photo chip state when the response comes back.
  ///
  /// Run "unawaited" so the picker UI doesn't sit blocking on the
  /// network; all state updates re-check [mounted] because users can
  /// leave the page mid-flight.
  ///
  /// Registers a fresh [CancelToken] in [_classifyCancelToken]. If a
  /// previous classify is still in flight (user added another batch
  /// before the first one responded) we cancel it first so the two
  /// don't stack on the server. [_submit] also cancels via the same
  /// handle right before the upload starts.
  void _runClassifyAssignment({
    required int baseIdx,
    required List<File> files,
  }) {
    _classifyCancelToken?.cancel('superseded by newer classify');
    final token = CancelToken();
    _classifyCancelToken = token;

    unawaited(() async {
      try {
        final service = ref.read(_classifyServiceProvider);
        final results = await service.classify(files, cancelToken: token);
        if (!mounted) return;

        setState(() {
          // Clear "识别中" for every file in the batch first — partial
          // responses from the server will overwrite with specifics.
          // Skip photos the user has already hand-picked; their chip
          // is already resolved and must not be disturbed.
          for (int i = 0; i < files.length; i++) {
            final absIdx = baseIdx + i;
            if (absIdx >= _isRecognizing.length) continue;
            if (absIdx < _userPicked.length && _userPicked[absIdx]) continue;
            _isRecognizing[absIdx] = false;
          }

          for (final r in results) {
            final absIdx = baseIdx + r.fileIndex;
            if (absIdx < 0 || absIdx >= _assignedPetIds.length) continue;
            // Always record the model's original suggestion, even if
            // the user has already hand-picked — the feedback path
            // wants to know what the model said regardless of whether
            // the user waited for it.
            if (absIdx < _originalAssignedPetIds.length) {
              _originalAssignedPetIds[absIdx] = r.petId;
              _originalConfidences[absIdx] = r.confidence;
            }
            if (absIdx < _userPicked.length && _userPicked[absIdx]) continue;
            _assignedPetIds[absIdx] = r.petId;
            _wasAutoAssigned[absIdx] = r.petId != null;
          }
        });
      } on DioException catch (e) {
        // Cancellation is an expected outcome — either _submit() ran
        // or a newer classify replaced us. Keep the UI quiet; the
        // "识别中" flag is cleared below on any exit path so the chip
        // never spins forever.
        if (e.type != DioExceptionType.cancel) {
          // ClassifyService already printed a one-liner summary for
          // real transport faults, so nothing more to say here.
        }
        if (!mounted) return;
        setState(() {
          for (int i = 0; i < files.length; i++) {
            final absIdx = baseIdx + i;
            if (absIdx >= _isRecognizing.length) continue;
            if (absIdx < _userPicked.length && _userPicked[absIdx]) continue;
            _isRecognizing[absIdx] = false;
            if (e.type != DioExceptionType.cancel) {
              _wasAutoAssigned[absIdx] = false;
            }
          }
        });
      } catch (_) {
        // Defensive: any non-Dio error still has to settle the UI.
        if (!mounted) return;
        setState(() {
          for (int i = 0; i < files.length; i++) {
            final absIdx = baseIdx + i;
            if (absIdx >= _isRecognizing.length) continue;
            if (absIdx < _userPicked.length && _userPicked[absIdx]) continue;
            _isRecognizing[absIdx] = false;
            _wasAutoAssigned[absIdx] = false;
          }
        });
      } finally {
        // Only clear the field if nobody else has replaced it already.
        if (identical(_classifyCancelToken, token)) {
          _classifyCancelToken = null;
        }
      }
    }());
  }

  void _showRecognizingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => const PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              BrandPulse(size: 24),
              SizedBox(width: 12),
              Text('正在识别照片...'),
            ],
          ),
        ),
      ),
    );
  }

  /// Copy the compressed JPEG into the persistent cache so that once the
  /// upload succeeds we can bind it to the new `photo_id` and reuse the bytes
  /// across restarts. Returns an opaque token.
  Future<String> _cachePending(File source) async {
    try {
      return await OriginalPhotoCache.instance.cacheUploadSource(source);
    } catch (_) {
      // Falling back to an empty token means the cache simply won't have this
      // photo until it is later viewed; we don't block the upload flow.
      return '';
    }
  }

  /// Compress image for upload: 1920x1080, quality 90.
  /// To upload the original file instead, return File(xfile.path) directly.
  Future<File> _ensureJpeg(XFile xfile) async {
    final dir = await getTemporaryDirectory();
    final outPath = '${dir.path}/${DateTime.now().millisecondsSinceEpoch}.jpg';
    final result = await FlutterImageCompress.compressAndGetFile(
      xfile.path,
      outPath,
      minWidth: 1920,
      minHeight: 1080,
      format: CompressFormat.jpeg,
      quality: 90,
    );
    if (result != null) return File(result.path);
    return File(xfile.path);
  }

  void _removePhoto(int index) {
    final token = index < _pendingTokens.length ? _pendingTokens[index] : '';
    if (token.isNotEmpty) {
      OriginalPhotoCache.instance.releasePending(token);
    }
    setState(() {
      _selectedFiles.removeAt(index);
      if (index < _pendingTokens.length) {
        _pendingTokens.removeAt(index);
      }
      _photoDates.removeAt(index);
      if (index < _assignedPetIds.length) _assignedPetIds.removeAt(index);
      if (index < _wasAutoAssigned.length) _wasAutoAssigned.removeAt(index);
      if (index < _originalAssignedPetIds.length) {
        _originalAssignedPetIds.removeAt(index);
      }
      if (index < _originalConfidences.length) {
        _originalConfidences.removeAt(index);
      }
      if (index < _isRecognizing.length) _isRecognizing.removeAt(index);
      if (index < _userPicked.length) _userPicked.removeAt(index);
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
    if (_selectedFiles.isEmpty) return;

    // Every photo must have a pet chip before we can group. Callers
    // can always tap to pick so this is just a gentle guard.
    final unassigned = <int>[];
    for (int i = 0; i < _assignedPetIds.length; i++) {
      if (_assignedPetIds[i] == null) unassigned.add(i + 1);
    }
    if (unassigned.isNotEmpty) {
      _showSnack('第 ${unassigned.join("、")} 张还没选择宠物哦');
      return;
    }

    // Group photo indices by pet so we can make one upload call per pet.
    final Map<int, List<int>> groups = {};
    for (int i = 0; i < _selectedFiles.length; i++) {
      final pid = _assignedPetIds[i];
      if (pid == null) continue;
      groups.putIfAbsent(pid, () => []).add(i);
    }

    // Abort any still-running classify *before* the upload starts.
    // Each classify request occupies one DashScope thread per file on
    // the server; leaving 5 of them in flight while the upload POST
    // is trying to land caused the "progress bar crawls / 上传完停顿"
    // symptoms we debugged on 2026-04-22. The user has already chosen
    // a pet per photo by this point, so the pending soft-guess has
    // no remaining value.
    _classifyCancelToken?.cancel('upload starts');
    _classifyCancelToken = null;

    setState(() {
      _isUploading = true;
      _failureMessages = {};
      // Clear any leftover "识别中" spinner rows so the upload dialog
      // isn't rendered behind a stale chip spinner.
      for (int i = 0; i < _isRecognizing.length; i++) {
        _isRecognizing[i] = false;
      }
    });
    _uploadProgress.value = 0;
    _isServerProcessing.value = false;

    _showUploadDialog();

    final service = ref.read(_photoServiceProvider);

    final Set<int> allSuccessIndices = {};
    final Map<int, String> newFailureMessages = {};
    int totalSent = 0;

    // Weight each group's progress by its share of total files so the
    // HUD advances smoothly across multi-group submits.
    final totalFiles = _selectedFiles.length;

    try {
      int groupsDone = 0;
      for (final entry in groups.entries) {
        final petId = entry.key;
        final indices = entry.value;
        final files = [for (final i in indices) _selectedFiles[i]];
        final dates = [
          for (final i in indices) _dateFormat.format(_photoDates[i])
        ];
        final sources = [
          for (final i in indices) _wasAutoAssigned[i] ? 'auto' : 'corrected'
        ];
        // Option A feedback plumbing: send the model's original guess
        // and its confidence alongside every file so the server can
        // log structured correction events. Safe to send for "auto"
        // rows too — the backend only writes a feedback row when the
        // row's classify_source is "corrected".
        final prevPetIds = [
          for (final i in indices)
            i < _originalAssignedPetIds.length
                ? _originalAssignedPetIds[i]
                : null,
        ];
        final prevConfidences = [
          for (final i in indices)
            i < _originalConfidences.length
                ? _originalConfidences[i]
                : null,
        ];

        final response = await service.uploadPhotos(
          petId: petId,
          files: files,
          takenAtDates: dates,
          classifySources: sources,
          previousPetIds: prevPetIds,
          previousTop1Similarities: prevConfidences,
          onSendProgress: (sent, total) {
            if (total <= 0) return;
            // Fraction within this group, rescaled by (group_files / total_files).
            final groupShare = files.length / totalFiles;
            final baseProgress = groupsDone / groups.length;
            final within = (sent / total) * groupShare;
            final progress = (baseProgress + within).clamp(0.0, 1.0);
            _uploadProgress.value = progress;
            if (progress >= 1.0 && !_isServerProcessing.value) {
              _isServerProcessing.value = true;
            }
          },
        );

        totalSent += response.totalCount;
        groupsDone++;

        // Bind cache + collect absolute successes/failures.
        await _bindGroupUploadedToCache(response, indices);
        for (final s in response.successes) {
          final abs = s.index < indices.length ? indices[s.index] : null;
          if (abs != null) allSuccessIndices.add(abs);
        }
        for (final f in response.failures) {
          final abs = f.index < indices.length ? indices[f.index] : null;
          if (abs != null) newFailureMessages[abs] = f.message;
        }
      }

      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      _applyUploadResult(
        totalCount: totalSent,
        successIndices: allSuccessIndices,
        failureMessagesByAbs: newFailureMessages,
      );
    } on DioException catch (e) {
      if (!mounted) return;
      Navigator.of(context, rootNavigator: true).pop();

      final data = e.response?.data;
      String message = '上传失败，请稍后重试';
      if (data is Map<String, dynamic>) {
        message = (data['message'] as String?) ?? message;
      }
      _showSnack(message);
    } catch (_) {
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
        child: ValueListenableBuilder<bool>(
          valueListenable: _isServerProcessing,
          builder: (ctx, isProcessing, _) {
            if (isProcessing) {
              return AlertDialog(
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('正在识别照片...',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 16),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 8),
                    Text(
                      '共 $fileCount 张，正在检测宠物内容',
                      style: const TextStyle(
                          fontSize: 12, color: AppTheme.textSecondary),
                    ),
                  ],
                ),
              );
            }
            return ValueListenableBuilder<double>(
              valueListenable: _uploadProgress,
              builder: (ctx, progress, _) {
                return AlertDialog(
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('正在上传照片...',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 16),
                      LinearProgressIndicator(value: progress),
                      const SizedBox(height: 8),
                      Text(
                        '${(progress * 100).toInt()}%',
                        style:
                            const TextStyle(color: AppTheme.textSecondary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '共 $fileCount 张，请勿关闭页面',
                        style: const TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  /// Promote pending cache entries to photo-id bound entries for the
  /// successes in a single group's response. Failures keep their
  /// pending token so the file can be reused on retry.
  Future<void> _bindGroupUploadedToCache(
    PhotoUploadResponse response,
    List<int> groupIndices,
  ) async {
    for (final success in response.successes) {
      if (success.index < 0 || success.index >= groupIndices.length) continue;
      final absIdx = groupIndices[success.index];
      if (absIdx < 0 || absIdx >= _pendingTokens.length) continue;
      final token = _pendingTokens[absIdx];
      if (token.isEmpty) continue;
      try {
        await OriginalPhotoCache.instance
            .bindPendingToPhoto(token, success.photo.id);
      } catch (_) {
        // Best-effort.
      }
    }
  }

  /// Update list state after all groups have responded. Rebuilds the
  /// card list by absolute index so half-failed submits keep the user
  /// in the right place.
  void _applyUploadResult({
    required int totalCount,
    required Set<int> successIndices,
    required Map<int, String> failureMessagesByAbs,
  }) {
    final successCount = successIndices.length;
    final failureCount = totalCount - successCount;

    if (failureCount == 0) {
      _showSnack('上传成功，请在时间轴内查看吧！');
      setState(() {
        _selectedFiles.clear();
        _pendingTokens.clear();
        _photoDates.clear();
        _assignedPetIds.clear();
        _wasAutoAssigned.clear();
        _isRecognizing.clear();
        _userPicked.clear();
        _originalAssignedPetIds.clear();
        _originalConfidences.clear();
        _failureMessages = {};
      });
      return;
    }

    if (successCount > 0) {
      _showSnack('已成功上传 $successCount 张，失败 $failureCount 张');
    } else {
      _showSnack('本次未成功上传，请检查失败原因后重试');
    }

    final newFiles = <File>[];
    final newDates = <DateTime>[];
    final newTokens = <String>[];
    final newAssigned = <int?>[];
    final newAuto = <bool>[];
    final newRecog = <bool>[];
    final newPicked = <bool>[];
    final newOriginalAssigned = <int?>[];
    final newOriginalConfidence = <double?>[];
    final newFailures = <int, String>{};

    int newIdx = 0;
    for (int i = 0; i < _selectedFiles.length; i++) {
      if (successIndices.contains(i)) continue;
      newFiles.add(_selectedFiles[i]);
      newDates.add(_photoDates[i]);
      newTokens.add(i < _pendingTokens.length ? _pendingTokens[i] : '');
      newAssigned.add(i < _assignedPetIds.length ? _assignedPetIds[i] : null);
      newAuto.add(i < _wasAutoAssigned.length ? _wasAutoAssigned[i] : false);
      newRecog.add(false);
      newPicked.add(i < _userPicked.length ? _userPicked[i] : false);
      newOriginalAssigned.add(
        i < _originalAssignedPetIds.length
            ? _originalAssignedPetIds[i]
            : null,
      );
      newOriginalConfidence.add(
        i < _originalConfidences.length ? _originalConfidences[i] : null,
      );
      final msg = failureMessagesByAbs[i];
      if (msg != null) newFailures[newIdx] = msg;
      newIdx++;
    }

    setState(() {
      _selectedFiles
        ..clear()
        ..addAll(newFiles);
      _photoDates
        ..clear()
        ..addAll(newDates);
      _pendingTokens
        ..clear()
        ..addAll(newTokens);
      _assignedPetIds
        ..clear()
        ..addAll(newAssigned);
      _wasAutoAssigned
        ..clear()
        ..addAll(newAuto);
      _isRecognizing
        ..clear()
        ..addAll(newRecog);
      _userPicked
        ..clear()
        ..addAll(newPicked);
      _originalAssignedPetIds
        ..clear()
        ..addAll(newOriginalAssigned);
      _originalConfidences
        ..clear()
        ..addAll(newOriginalConfidence);
      _failureMessages = newFailures;
    });
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
          content: Text(msg), behavior: SnackBarBehavior.floating));
  }

  // ------------------ Voice intake ------------------

  /// Called by [VoiceRecordButton] with the finished clip. Same as
  /// Phase 2 Step 2 — we no longer carry a global selectedPet, so the
  /// voice intake uses the first editable pet as default (if any).
  Future<void> _handleVoiceClipReady(File audioFile) async {
    setState(() => _voiceProcessing = true);

    try {
      final service = ref.read(_voiceServiceProvider);
      final editable = _editableCandidatePets;
      final defaultPetId = editable.isNotEmpty ? editable.first.id : null;
      final clientReqId = _uuid.v4();

      final response = await service.intake(
        audioFile: audioFile,
        clientRequestId: clientReqId,
        defaultPetId: defaultPetId,
      );

      if (!mounted) return;

      switch (response.status) {
        case VoiceIntakeStatus.sttFailed:
          _showSnack('没听清，请再说一次');
          break;
        case VoiceIntakeStatus.intentUnknown:
          await _showTranscriptFallbackSheet(response);
          break;
        case VoiceIntakeStatus.draftPending:
          await _showDraftReviewSheet(response);
          break;
      }
    } on DioException catch (e) {
      if (!mounted) return;
      _showSnack(_voiceFriendlyError(e));
    } catch (_) {
      if (!mounted) return;
      _showSnack('语音识别失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _voiceProcessing = false);
      // Local audio cleanup — server already has its own copy.
      try {
        await audioFile.delete();
      } catch (_) {}
    }
  }

  Future<void> _showDraftReviewSheet(VoiceIntakeResponse response) async {
    final pets = ref.read(petListProvider).valueOrNull?.pets ?? const [];
    final service = ref.read(_voiceServiceProvider);

    final result = await showVoiceIntakeSheet(
      context,
      response: response,
      pets: pets,
      service: service,
    );

    if (result == null || !mounted) return;

    // Refresh the matching list + status providers so the new record is
    // visible next time the user opens the health screen / cycle status.
    _invalidateProvidersForIntent(response.intent, result.entity);

    final intentLabel = response.intent == null
        ? '记录'
        : '${voiceIntentLabel(response.intent!)}记录';
    _showSnack('已创建$intentLabel');
  }

  void _invalidateProvidersForIntent(
    VoiceIntent? intent,
    Map<String, dynamic> entity,
  ) {
    final petId = entity['pet_id'] as int?;
    if (petId == null || intent == null) return;
    switch (intent) {
      case VoiceIntent.deworming:
        ref.invalidate(dewormingListProvider(petId));
        ref.invalidate(dewormingStatusProvider(petId));
        break;
      case VoiceIntent.vaccination:
        ref.invalidate(vaccinationListProvider(petId));
        break;
      case VoiceIntent.weight:
        ref.invalidate(weightListProvider(petId));
        break;
      case VoiceIntent.routine:
        ref.invalidate(routineListProvider(petId));
        ref.invalidate(routineStatusProvider(petId));
        break;
      case VoiceIntent.unknown:
        break;
    }
  }

  Future<void> _showTranscriptFallbackSheet(VoiceIntakeResponse response) async {
    final transcript = response.transcript ?? '';
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('没能识别出想记录的事',
                  style: TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF4EE),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  transcript.isEmpty ? '（未识别到语音内容）' : '"$transcript"',
                  style: const TextStyle(fontSize: 14),
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '请换一种说法再试，例如："今天给咪咪做了体内驱虫"。',
                style:
                    TextStyle(fontSize: 13, color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 44,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryColor,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('我再说一遍',
                      style: TextStyle(
                          fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _voiceFriendlyError(DioException e) {
    final data = e.response?.data;
    if (data is Map && data['message'] is String) {
      return data['message'] as String;
    }
    final code = e.response?.statusCode;
    if (code == 503) return '语音服务暂时不可用，请稍后再试';
    return '语音识别失败，请稍后重试';
  }
}
