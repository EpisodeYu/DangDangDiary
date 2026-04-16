import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/theme.dart';
import '../../models/pet.dart';
import '../../providers/pet_provider.dart';

const _catBreeds = [
  '中华田园猫', '美国短毛猫', '英国短毛猫', '布偶猫', '暹罗猫',
  '橘猫', '奶牛猫', '三花猫', '狸花猫', '波斯猫',
  '缅因猫', '斯芬克斯猫', '苏格兰折耳猫', '俄罗斯蓝猫', '其他',
];

const _dogBreeds = [
  '中华田园犬', '柴犬', '金毛犬', '拉布拉多', '泰迪/贵宾',
  '柯基', '哈士奇', '萨摩耶', '边牧', '博美',
  '比熊', '法斗', '德牧', '雪纳瑞', '其他',
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

  String _petType = 'cat';
  DateTime? _birthday;
  Uint8List? _avatarBytes;
  String? _avatarFilename;
  Pet? _existingPet;
  bool _isLoading = false;
  bool _isInitialized = false;

  bool get _isEditing => widget.petId != null;

  @override
  void dispose() {
    _nameController.dispose();
    _breedController.dispose();
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
          ],
        ),
      ),
    );
  }

  Widget _buildAvatarSection() {
    return Center(
      child: GestureDetector(
        onTap: _isEditing ? _pickAndUploadAvatar : _pickAvatar,
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
              child: _buildTypeButton('cat', '🐱 猫'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _buildTypeButton('dog', '🐶 狗'),
            ),
          ],
        ),
        if (_isEditing)
          const Padding(
            padding: EdgeInsets.only(top: 4),
            child: Text(
              '编辑模式下不可修改宠物类型',
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
      decoration: InputDecoration(
        labelText: '宠物名字 *',
        hintText: '请输入宠物名字',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor: Colors.white,
      ),
      validator: (value) {
        if (value == null || value.trim().isEmpty) return '请输入宠物名字';
        if (value.trim().length > 50) return '名字不能超过50个字符';
        return null;
      },
    );
  }

  Widget _buildBreedField() {
    final breeds = _petType == 'cat' ? _catBreeds : _dogBreeds;
    return Autocomplete<String>(
      optionsBuilder: (textEditingValue) {
        if (textEditingValue.text.isEmpty) return breeds;
        return breeds.where(
          (b) => b.contains(textEditingValue.text),
        );
      },
      initialValue: TextEditingValue(text: _breedController.text),
      onSelected: (value) => _breedController.text = value,
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        _breedController.text = controller.text;
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
          onChanged: (v) => _breedController.text = v,
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

  Future<void> _pickBirthday() async {
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

  Future<void> _pickAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512);
    if (file != null) {
      final bytes = await file.readAsBytes();
      setState(() {
        _avatarBytes = bytes;
        _avatarFilename = file.name;
      });
    }
  }

  Future<void> _pickAndUploadAvatar() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(source: ImageSource.gallery, maxWidth: 512);
    if (file == null) return;

    final bytes = await file.readAsBytes();
    setState(() {
      _avatarBytes = bytes;
      _avatarFilename = file.name;
    });

    if (widget.petId != null) {
      try {
        await ref.read(petServiceProvider).uploadAvatar(
          widget.petId!,
          bytes,
          file.name,
        );
        ref.read(petListProvider.notifier).refresh();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('头像上传失败: $e')),
          );
        }
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
          await service.uploadAvatar(created.id, _avatarBytes!, _avatarFilename!);
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
