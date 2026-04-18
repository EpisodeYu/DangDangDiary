import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../../config/theme.dart';
import '../../models/pet.dart';
import '../../providers/pet_provider.dart';

const _catBreeds = [
  '中华田园猫', '英国短毛猫', '美国短毛猫', '布偶猫', '暹罗猫',
  '异国短毛猫（加菲猫）', '缅因猫', '波斯猫', '曼基康矮脚猫', '斯芬克斯无毛猫',
  '苏格兰折耳猫', '俄罗斯蓝猫', '孟加拉豹猫', '德文卷毛猫', '阿比西尼亚猫',
  '挪威森林猫', '西伯利亚森林猫', '伯曼猫', '柯尼斯卷毛猫', '东方短毛猫',
  '索马里猫', '埃及猫', '新加坡猫', '其他',
];

// Non-ASCII runes (CJK, emoji, etc.) weigh 2; ASCII weighs 1. Caps display
// width so a name like "A" * 30 and "汉" * 15 hit the same limit.
int _weightedLength(String s) {
  var w = 0;
  for (final r in s.runes) {
    w += r < 0x80 ? 1 : 2;
  }
  return w;
}

class _WeightedLengthFormatter extends TextInputFormatter {
  final int max;
  const _WeightedLengthFormatter(this.max);

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (_weightedLength(newValue.text) <= max) return newValue;
    return oldValue;
  }
}

const _dogBreeds = [
  '贵宾犬（泰迪）', '中华田园犬', '威尔士柯基犬', '金毛寻回犬', '比熊犬',
  '拉布拉多寻回犬', '博美犬', '西伯利亚雪橇犬（哈士奇）', '法国斗牛犬', '柴犬',
  '边境牧羊犬', '萨摩耶犬', '雪纳瑞犬', '阿拉斯加雪橇犬', '吉娃娃',
  '巴哥犬', '德国牧羊犬', '约克夏梗', '马尔济斯犬', '腊肠犬',
  '罗威纳犬', '杜宾犬', '比格犬', '英国斗牛犬', '蝴蝶犬',
  '西施犬', '松狮犬', '可卡犬', '牛头梗', '喜乐蒂牧羊犬',
  '伯恩山犬', '大丹犬', '阿富汗猎犬', '其他',
];

class PetEditScreen extends ConsumerStatefulWidget {
  final int? petId;

  const PetEditScreen({super.key, this.petId});

  @override
  ConsumerState<PetEditScreen> createState() => _PetEditScreenState();
}

class _PetEditScreenState extends ConsumerState<PetEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _breedController = TextEditingController();
  final _breedFocusNode = FocusNode();

  String _petType = 'cat';
  DateTime? _birthday;
  Uint8List? _avatarBytes;
  String? _avatarFilename;
  Pet? _existingPet;
  bool _isLoading = false;
  bool _isInitialized = false;
  double? _uploadProgress;

  bool get _isEditing => widget.petId != null;

  @override
  void dispose() {
    _nameController.dispose();
    _breedController.dispose();
    _breedFocusNode.dispose();
    super.dispose();
  }

  void _initFromPet(Pet pet) {
    if (_isInitialized) return;
    _isInitialized = true;
    _existingPet = pet;
    _nameController.text = pet.name;
    _breedController.text = pet.breed ?? '';
    _petType = pet.petType;
    if (pet.birthday != null && pet.birthday!.isNotEmpty) {
      _birthday = DateTime.tryParse(pet.birthday!);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isEditing) {
      final petListAsync = ref.watch(petListProvider);
      final pets = petListAsync.valueOrNull?.pets ?? [];
      final pet = pets.where((p) => p.id == widget.petId).firstOrNull;
      if (pet != null) _initFromPet(pet);
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing ? '编辑宠物档案' : '创建宠物档案'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            _buildAvatarSection(),
            const SizedBox(height: 24),
            _buildPetTypeSection(),
            const SizedBox(height: 20),
            _buildNameField(),
            const SizedBox(height: 16),
            _buildBreedField(),
            const SizedBox(height: 16),
            _buildBirthdayField(),
            const SizedBox(height: 32),
            _buildSaveButton(),
            if (_isEditing) ...[
              const SizedBox(height: 16),
              _buildDeleteButton(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarSection() {
    final isUploading = _uploadProgress != null;
    return Center(
      child: GestureDetector(
        onTap: isUploading ? null : (_isEditing ? _pickAndUploadAvatar : _pickAvatar),
        child: Stack(
          children: [
            CircleAvatar(
              radius: 48,
              backgroundColor: AppTheme.secondaryColor.withValues(alpha: 0.3),
              backgroundImage: _avatarBytes != null
                  ? MemoryImage(_avatarBytes!)
                  : (_existingPet?.avatarUrl != null
                      ? NetworkImage(_existingPet!.avatarUrl!)
                      : null),
              child: _avatarBytes == null && _existingPet?.avatarUrl == null
                  ? const Icon(Icons.camera_alt, size: 32, color: AppTheme.primaryColor)
                  : null,
            ),
            if (isUploading)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.black.withValues(alpha: 0.5),
                  ),
                  child: Center(
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: CircularProgressIndicator(
                        value: _uploadProgress,
                        strokeWidth: 3,
                        color: Colors.white,
                        backgroundColor: Colors.white.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
              ),
            if (!isUploading)
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 2),
                  ),
                  child: const Icon(Icons.edit, size: 14, color: Colors.white),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildPetTypeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('宠物类型', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _buildTypeButton('cat', '猫猫'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildTypeButton('dog', '狗狗'),
            ),
          ],
        ),
        if (_isEditing)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '宠物类型不支持修改',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
      ],
    );
  }

  Widget _buildTypeButton(String type, String label) {
    final isSelected = _petType == type;
    final isDisabled = _isEditing;
    return GestureDetector(
      onTap: isDisabled ? null : () => setState(() {
        _petType = type;
        _breedController.clear();
      }),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primaryColor.withValues(alpha: 0.12)
              : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected ? AppTheme.primaryColor : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: isDisabled && !isSelected
                  ? AppTheme.textSecondary
                  : (isSelected ? AppTheme.primaryColor : AppTheme.textPrimary),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNameField() {
    return TextFormField(
      controller: _nameController,
      inputFormatters: const [_WeightedLengthFormatter(30)],
      decoration: InputDecoration(
        labelText: '宠物名字 *',
        hintText: '最多 15 个汉字或 30 个字符',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
      validator: (value) {
        if (value == null || value.trim().isEmpty) return '请输入宠物名字';
        if (_weightedLength(value.trim()) > 30) {
          return '名字过长（最多 15 个汉字或 30 个字符）';
        }
        return null;
      },
    );
  }

  Widget _buildBreedField() {
    final breeds = _petType == 'cat' ? _catBreeds : _dogBreeds;
    return RawAutocomplete<String>(
      textEditingController: _breedController,
      focusNode: _breedFocusNode,
      optionsBuilder: (textEditingValue) {
        if (textEditingValue.text.isEmpty) return breeds;
        return breeds.where((b) => b.contains(textEditingValue.text));
      },
      onSelected: (value) {
        _breedController.text = value;
        _breedFocusNode.unfocus();
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextFormField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: '品种',
            hintText: '选择或输入品种',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: Colors.white,
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: options.length,
                itemBuilder: (context, index) {
                  final option = options.elementAt(index);
                  return InkWell(
                    onTap: () => onSelected(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Text(option, style: const TextStyle(fontSize: 15)),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBirthdayField() {
    return GestureDetector(
      onTap: _pickBirthday,
      child: AbsorbPointer(
        child: TextFormField(
          decoration: InputDecoration(
            labelText: '生日',
            hintText: '点击选择日期',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
            filled: true,
            fillColor: Colors.white,
            suffixIcon: const Icon(Icons.calendar_today),
          ),
          controller: TextEditingController(
            text: _birthday != null
                ? '${_birthday!.year}-${_birthday!.month.toString().padLeft(2, '0')}-${_birthday!.day.toString().padLeft(2, '0')}'
                : '',
          ),
        ),
      ),
    );
  }

  Widget _buildSaveButton() {
    return SizedBox(
      height: 48,
      child: ElevatedButton(
        onPressed: _isLoading ? null : _save,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppTheme.primaryColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
        child: _isLoading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Text('保存', style: TextStyle(fontSize: 16)),
      ),
    );
  }

  Widget _buildDeleteButton() {
    return SizedBox(
      height: 48,
      child: OutlinedButton.icon(
        onPressed: _isLoading ? null : _confirmAndDelete,
        icon: const Icon(Icons.delete_outline),
        label: const Text('删除此宠物档案', style: TextStyle(fontSize: 16)),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.errorColor,
          side: const BorderSide(color: AppTheme.errorColor),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
    );
  }

  Future<void> _confirmAndDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除宠物档案'),
        content: const Text('删除后将清除该宠物的所有数据，包括照片、体重、驱虫和疫苗记录。此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorColor),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isLoading = true);
    try {
      await ref.read(petServiceProvider).deletePet(widget.petId!);

      final selectedId = ref.read(selectedPetIdProvider);
      if (selectedId == widget.petId) {
        ref.read(selectedPetIdProvider.notifier).select(null);
      }
      ref.read(petListProvider.notifier).refresh();

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickBirthday() async {
    FocusManager.instance.primaryFocus?.unfocus();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday ?? DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) {
      setState(() => _birthday = picked);
    }
  }

  /// Compress the picked image down to an avatar-sized JPEG.
  /// image_picker's default is quality 100, which produces ~300KB files even
  /// at maxWidth: 512 — way too large for a 96px CircleAvatar. This runs a
  /// second pass through flutter_image_compress to land at ~30–60KB.
  Future<({Uint8List bytes, String filename})?> _compressAvatar(XFile xfile) async {
    final dir = await getTemporaryDirectory();
    final outPath = '${dir.path}/avatar_${DateTime.now().millisecondsSinceEpoch}.jpg';
    final result = await FlutterImageCompress.compressAndGetFile(
      xfile.path,
      outPath,
      minWidth: 400,
      minHeight: 400,
      format: CompressFormat.jpeg,
      quality: 80,
    );
    if (result == null) {
      final raw = await xfile.readAsBytes();
      return (bytes: raw, filename: xfile.name);
    }
    final bytes = await File(result.path).readAsBytes();
    return (bytes: bytes, filename: 'avatar.jpg');
  }

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;
    final compressed = await _compressAvatar(file);
    if (compressed == null || !mounted) return;
    setState(() {
      _avatarBytes = compressed.bytes;
      _avatarFilename = compressed.filename;
    });
  }

  Future<void> _pickAndUploadAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) return;

    final compressed = await _compressAvatar(file);
    if (compressed == null || !mounted) return;
    final bytes = compressed.bytes;
    setState(() {
      _avatarBytes = bytes;
      _avatarFilename = compressed.filename;
    });

    if (widget.petId != null) {
      setState(() => _uploadProgress = 0);
      try {
        await ref.read(petServiceProvider).uploadAvatar(
          widget.petId!,
          bytes,
          compressed.filename,
          onSendProgress: (sent, total) {
            if (mounted && total > 0) {
              setState(() => _uploadProgress = sent / total);
            }
          },
        );
        ref.read(petListProvider.notifier).refresh();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('头像上传成功'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('头像上传失败: $e')),
          );
        }
      } finally {
        if (mounted) setState(() => _uploadProgress = null);
      }
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final service = ref.read(petServiceProvider);
    final birthdayStr = _birthday != null
        ? '${_birthday!.year}-${_birthday!.month.toString().padLeft(2, '0')}-${_birthday!.day.toString().padLeft(2, '0')}'
        : null;

    try {
      if (_isEditing) {
        await service.updatePet(
          widget.petId!,
          name: _nameController.text.trim(),
          breed: _breedController.text.trim().isEmpty ? null : _breedController.text.trim(),
          birthday: birthdayStr,
        );
      } else {
        final created = await service.createPet(
          name: _nameController.text.trim(),
          petType: _petType,
          breed: _breedController.text.trim().isEmpty ? null : _breedController.text.trim(),
          birthday: birthdayStr,
        );

        if (_avatarBytes != null && _avatarFilename != null) {
          setState(() => _uploadProgress = 0);
          await service.uploadAvatar(
            created.id,
            _avatarBytes!,
            _avatarFilename!,
            onSendProgress: (sent, total) {
              if (mounted && total > 0) {
                setState(() => _uploadProgress = sent / total);
              }
            },
          );
          if (mounted) setState(() => _uploadProgress = null);
        }

        ref.read(selectedPetIdProvider.notifier).select(created.id);
      }

      ref.read(petListProvider.notifier).refresh();

      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }
}
