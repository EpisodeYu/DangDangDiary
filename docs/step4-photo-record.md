# Step 4: 照片记录

## 项目背景

「当当日记」是一个宠物日记 APP，使用 Flutter + FastAPI + PostgreSQL + MinIO 技术栈。本步骤实现宠物照片的上传与记录功能。

**前置依赖**: Step 3 已完成，宠物档案管理可用，MinIO 存储服务已封装。

---

## 本步骤目标

1. 后端实现照片上传 API (支持批量上传，每次最多 5 张，单张 <= 15MB)
2. 后端实现宠物图片校验 (调用阿里云场景识别 API，拒绝非宠物图片)
3. 后端实现照片缩略图生成
4. Flutter 实现「记录」页面 (选档案、选照片、日期选择)
5. Flutter 实现 EXIF 日期提取
6. 照片记录完成后页面重置

---

## 1. 照片存储架构

```
MinIO Buckets:
├── pet-photos/          # 原图
│   ├── {pet_id}/{uuid}.jpg
│   └── {pet_id}/{uuid}.png
└── pet-thumbnails/      # 缩略图 (后端生成)
    ├── {pet_id}/{uuid}_thumb.jpg
    └── {pet_id}/{uuid}_thumb.jpg
```

- 原图: 保持用户上传的原始文件，单张限制 15MB
- 缩略图: 后端接收原图后，使用 Pillow 生成缩略图 (最大 400x400 像素, JPEG 质量 80)
- 文件名使用 UUID 避免冲突
- 按 pet_id 分目录，方便管理和清理

---

## 2. 后端 API 规格

### 2.1 上传照片

```
POST /api/v1/pets/{pet_id}/photos
Content-Type: multipart/form-data
Authorization: Bearer {access_token}
```

表单字段:
- `files`: 图片文件列表，最少 1 张，最多 5 张，每张 <= 15MB
- `taken_at`: 拍摄日期，格式 `YYYY-MM-DD`

支持的图片格式: JPEG, PNG, WEBP

补充说明:
- 若用户选择 HEIC/HEIF，Flutter 端先转换为 JPEG 后再上传
- 列表接口只返回可直接展示的缩略图 URL；查看原图时再单独请求签名 URL

成功响应 (201):
```json
{
  "photos": [
    {
      "id": 1,
      "pet_id": 1,
      "storage_key": "pet-photos/1/a1b2c3d4.jpg",
      "thumbnail_key": "pet-thumbnails/1/a1b2c3d4_thumb.jpg",
      "thumbnail_url": "http://YOUR_SERVER_IP/media/pet-thumbnails/1/a1b2c3d4_thumb.jpg",
      "taken_at": "2024-01-15",
      "created_at": "2024-01-20T10:30:00"
    },
    ...
  ],
  "count": 3
}
```

错误响应:
- 400: 文件格式不支持 / 文件过大 / 超过 5 张
- 403: 无权限访问该宠物档案

业务逻辑:
1. 验证用户对 pet_id 的访问权限 (通过 pet_members 表)
2. 验证文件数量 (1-5 张)
3. 逐个处理每张图片:
   a. 验证文件类型和大小
   b. **宠物图片校验**: 调用阿里云场景识别 (RecognizeScene) API，检测图片中是否包含猫/狗
   c. 如果未识别到宠物，返回 400 错误: `{"code": "PET_NOT_DETECTED", "message": "未识别到宠物，请换一张图片试试吧！", "details": {"failed_index": 0}}`
   d. 生成 UUID 文件名
   e. 处理 JPEG / PNG / WEBP 文件并上传原图到 MinIO `pet-photos` bucket
   f. 使用 Pillow 生成缩略图 (最大 400x400, JPEG)
   g. 上传缩略图到 MinIO `pet-thumbnails` bucket
   h. 生成对外可访问的 `thumbnail_url`
   i. 创建 photos 数据库记录
4. 返回所有创建的照片记录

错误响应 (400 - 非宠物图片):
```json
{
  "code": "PET_NOT_DETECTED",
  "message": "未识别到宠物，请换一张图片试试吧！",
  "details": {
    "failed_index": 2
  }
}
```
`details.failed_index` 表示第几张图片未通过校验 (0-based)，供前端标识具体是哪张图片。

### 2.2 获取宠物照片列表

```
GET /api/v1/pets/{pet_id}/photos?page=1&page_size=20
Authorization: Bearer {access_token}
```

查询参数:
- `page`: 页码，默认 1
- `page_size`: 每页数量，默认 20，最大 50

成功响应 (200):
```json
{
  "photos": [...],
  "total": 150,
  "page": 1,
  "page_size": 20,
  "total_pages": 8
}
```

排序: 按 taken_at 降序 (最新的在前)

### 2.3 删除照片

```
DELETE /api/v1/photos/{photo_id}
Authorization: Bearer {access_token}
```

成功响应 (204): No Content

业务逻辑:
- 验证用户对照片所属宠物档案的访问权限
- 从 MinIO 删除原图和缩略图
- 删除数据库记录

### 2.4 获取照片原图 URL (带签名)

```
GET /api/v1/photos/{photo_id}/url
Authorization: Bearer {access_token}
```

成功响应 (200):
```json
{
  "url": "http://YOUR_SERVER_IP/media/pet-photos/1/xxx.jpg?X-Amz-...",
  "expires_in": 3600
}
```

用途: 时间轴点击查看原图时使用。原图使用预签名 URL (1小时过期)，缩略图则使用固定的 `/media/...` 路径。

---

## 3. 后端实现要点

### 3.1 宠物图片校验服务 (`app/services/image_recognition.py`)

使用阿里云视觉智能开放平台的**场景识别 (RecognizeScene)** API，在照片上传时判断图片中是否包含猫/狗。

**API 关键信息:**
- **接口**: `RecognizeScene` (图像识别 imagerecog 2019-09-30)
- **Endpoint**: `imagerecog.cn-shanghai.aliyuncs.com`
- **Region**: `cn-shanghai`
- **SDK**: `alibabacloud_imagerecog20190930`
- **AccessKey**: 与短信服务共用同一组 AccessKey
- **输入**: 图片文件流 (使用 `RecognizeSceneAdvanceRequest`，直接传入二进制流，无需先上传到 OSS)
- **输出**: 场景标签列表，每个标签包含 `Value` (标签名) 和 `Confidence` (置信度)

**API 文档参考**: `docs/本文档为您介绍场景识别常用语言和常见情况的示例代码.md`

**实现代码:**

```python
import io
from alibabacloud_imagerecog20190930.client import Client
from alibabacloud_imagerecog20190930.models import RecognizeSceneAdvanceRequest
from alibabacloud_tea_openapi.models import Config
from alibabacloud_tea_util.models import RuntimeOptions
from app.config import settings

# 宠物相关的场景标签关键词 (英文，阿里云场景识别返回英文标签)
PET_KEYWORDS = {
    'cat', 'dog', 'kitten', 'puppy', 'pet', 'animal',
    'feline', 'canine', 'kitty', 'pup',
    'tabby', 'persian', 'siamese', 'husky', 'poodle',
    'golden retriever', 'labrador', 'corgi', 'shiba',
    'british shorthair', 'ragdoll',
}

class ImageRecognitionService:
    def __init__(self):
        if settings.ALIYUN_ACCESS_KEY_ID and settings.ALIYUN_ACCESS_KEY_SECRET:
            config = Config(
                access_key_id=settings.ALIYUN_ACCESS_KEY_ID,
                access_key_secret=settings.ALIYUN_ACCESS_KEY_SECRET,
                endpoint='imagerecog.cn-shanghai.aliyuncs.com',
                region_id='cn-shanghai',
            )
            self.client = Client(config)
        else:
            self.client = None

    async def is_pet_image(self, image_data: bytes) -> tuple[bool, list[str]]:
        """
        判断图片中是否包含宠物 (猫/狗)。
        返回 (是否为宠物图片, 识别到的标签列表)。
        开发模式 (未配置 AccessKey) 下直接放行。
        """
        if self.client is None:
            print("[DEV ImageRecog] 未配置 AccessKey，跳过宠物图片校验")
            return True, []

        try:
            request = RecognizeSceneAdvanceRequest()
            request.image_urlobject = io.BytesIO(image_data)
            runtime = RuntimeOptions()

            response = self.client.recognize_scene_advance(request, runtime)
            tags = response.body.data.tags if response.body.data else []

            detected_labels = []
            for tag in tags:
                label = tag.value.lower() if tag.value else ''
                confidence = tag.confidence if tag.confidence else 0
                detected_labels.append(f"{tag.value}({confidence:.2f})")

                # 检查标签是否包含宠物关键词
                for keyword in PET_KEYWORDS:
                    if keyword in label and confidence > 0.3:
                        print(f"[ImageRecog] 识别到宠物标签: {tag.value} (置信度: {confidence:.2f})")
                        return True, detected_labels

            print(f"[ImageRecog] 未识别到宠物，标签: {detected_labels}")
            return False, detected_labels

        except Exception as e:
            print(f"[ImageRecog Error] 场景识别异常: {e}")
            # 识别服务异常时放行，避免阻塞正常上传
            return True, []

image_recognition_service = ImageRecognitionService()
```

**需要安装的 SDK:**
```
pip install alibabacloud_imagerecog20190930
```

**在照片上传 API 中集成校验:**

```python
# app/api/v1/photos.py 中的上传逻辑
from app.services.image_recognition import image_recognition_service

@router.post("/pets/{pet_id}/photos", status_code=201)
async def upload_photos(
    pet_id: int,
    files: list[UploadFile],
    taken_at: str = Form(...),
    current_user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    # ... 权限和基础校验 ...

    for index, file in enumerate(files):
        content = await file.read()

        # 宠物图片校验
        is_pet, labels = await image_recognition_service.is_pet_image(content)
        if not is_pet:
            raise HTTPException(
                status_code=400,
                detail={
                    "code": "PET_NOT_DETECTED",
                    "message": "未识别到宠物，请换一张图片试试吧！",
                    "details": {
                        "failed_index": index,
                        "detected_labels": labels,
                    },
                }
            )

        await file.seek(0)
        # ... 后续上传逻辑 ...
```

**注意事项:**
- 场景识别 API 按调用次数计费，每张图片调用一次
- 阿里云视觉智能开放平台新用户有免费额度
- 识别服务异常时**放行**上传，避免因第三方服务故障阻塞核心功能
- 置信度阈值设为 0.3，宁可误放也不误拦（用户体验优先）
- `PET_KEYWORDS` 列表可根据实际识别结果持续补充

### 3.2 MinIO 存储服务 (`app/services/storage.py`)

```python
from minio import Minio
from minio.error import S3Error
from io import BytesIO
from PIL import Image
import uuid
from app.config import settings

class StorageService:
    def __init__(self):
        self.client = Minio(
            settings.MINIO_ENDPOINT,
            access_key=settings.MINIO_ACCESS_KEY,
            secret_key=settings.MINIO_SECRET_KEY,
            secure=settings.MINIO_SECURE,
        )
        self._ensure_buckets()

    def _ensure_buckets(self):
        for bucket in [
            settings.MINIO_BUCKET_PHOTOS,
            settings.MINIO_BUCKET_THUMBNAILS,
            settings.MINIO_BUCKET_AVATARS,
        ]:
            if not self.client.bucket_exists(bucket):
                self.client.make_bucket(bucket)

    def upload_photo(self, pet_id: int, file_data: bytes, content_type: str) -> tuple[str, str]:
        """上传原图并生成缩略图，返回 (storage_key, thumbnail_key)"""
        ext = "jpg" if "jpeg" in content_type or "jpg" in content_type else "png"
        file_uuid = str(uuid.uuid4())

        # 上传原图
        storage_key = f"{pet_id}/{file_uuid}.{ext}"
        self.client.put_object(
            settings.MINIO_BUCKET_PHOTOS,
            storage_key,
            BytesIO(file_data),
            length=len(file_data),
            content_type=content_type,
        )

        # 生成并上传缩略图
        thumbnail_key = f"{pet_id}/{file_uuid}_thumb.jpg"
        thumbnail_data = self._generate_thumbnail(file_data)
        self.client.put_object(
            settings.MINIO_BUCKET_THUMBNAILS,
            thumbnail_key,
            BytesIO(thumbnail_data),
            length=len(thumbnail_data),
            content_type="image/jpeg",
        )

        return storage_key, thumbnail_key

    def _generate_thumbnail(self, image_data: bytes, max_size: tuple = (400, 400)) -> bytes:
        img = Image.open(BytesIO(image_data))
        img.thumbnail(max_size, Image.LANCZOS)
        if img.mode in ("RGBA", "P"):
            img = img.convert("RGB")
        output = BytesIO()
        img.save(output, format="JPEG", quality=80)
        return output.getvalue()

    def get_public_media_url(self, key: str) -> str:
        return f"{settings.PUBLIC_BASE_URL}/media/{settings.MINIO_BUCKET_THUMBNAILS}/{key}"

    def get_presigned_url(self, bucket: str, key: str, expires_hours: int = 1) -> str:
        from datetime import timedelta
        return self.client.presigned_get_object(bucket, key, expires=timedelta(hours=expires_hours))

    def delete_object(self, bucket: str, key: str):
        self.client.remove_object(bucket, key)

storage_service = StorageService()
```

### 3.2 Pydantic Schema (`app/schemas/photo.py`)

```python
from pydantic import BaseModel
from datetime import date, datetime

class PhotoResponse(BaseModel):
    id: int
    pet_id: int
    storage_key: str
    thumbnail_key: str | None
    thumbnail_url: str
    taken_at: date
    created_at: datetime

    class Config:
        from_attributes = True

class PhotoUploadResponse(BaseModel):
    photos: list[PhotoResponse]
    count: int

class PhotoListResponse(BaseModel):
    photos: list[PhotoResponse]
    total: int
    page: int
    page_size: int
    total_pages: int
```

### 3.3 文件验证

```python
ALLOWED_CONTENT_TYPES = {
    "image/jpeg", "image/jpg", "image/png", "image/webp"
}
MAX_FILE_SIZE = 15 * 1024 * 1024  # 15MB
MAX_FILES_PER_UPLOAD = 5

async def validate_upload_files(files: list[UploadFile]):
    if len(files) > MAX_FILES_PER_UPLOAD:
        raise HTTPException(
            400,
            detail={
                "code": "TOO_MANY_FILES",
                "message": f"每次最多上传 {MAX_FILES_PER_UPLOAD} 张照片",
                "details": {"max_files": MAX_FILES_PER_UPLOAD},
            },
        )
    if len(files) == 0:
        raise HTTPException(
            400,
            detail={
                "code": "EMPTY_UPLOAD",
                "message": "请至少上传一张照片",
                "details": None,
            },
        )
    for f in files:
        if f.content_type not in ALLOWED_CONTENT_TYPES:
            raise HTTPException(
                400,
                detail={
                    "code": "UNSUPPORTED_IMAGE_TYPE",
                    "message": f"不支持的文件格式: {f.content_type}",
                    "details": {"content_type": f.content_type},
                },
            )
        content = await f.read()
        if len(content) > MAX_FILE_SIZE:
            raise HTTPException(
                400,
                detail={
                    "code": "FILE_TOO_LARGE",
                    "message": f"文件 {f.filename} 超过 15MB 限制",
                    "details": {"max_file_size": MAX_FILE_SIZE},
                },
            )
        await f.seek(0)
```

---

## 4. Flutter「记录」页面

### 4.1 页面布局

```
┌─────────────────────────────────┐
│  橘子 ▼    (宠物选择器)           │
├─────────────────────────────────┤
│                                 │
│  ┌─────┐ ┌─────┐ ┌─────┐      │
│  │     │ │     │ │  ＋  │      │
│  │ 📷  │ │ 📷  │ │ 添加 │      │
│  │     │ │     │ │     │      │
│  └──×──┘ └──×──┘ └─────┘      │
│  (已选照片预览，右上角×可删除)      │
│  (最多5张，横向滚动)              │
│                                 │
│  拍摄日期                        │
│  ┌─────────────────────────┐    │
│  │  2024-01-15    📅        │    │
│  └─────────────────────────┘    │
│  (从EXIF自动获取，可手动修改)      │
│                                 │
│                                 │
│  ┌─────────────────────────┐    │
│  │       记录完成            │    │
│  └─────────────────────────┘    │
│                                 │
└─────────────────────────────────┘
│  记录  │  健康  │ 时间轴 │  AI  │ 我的 │
└─────────────────────────────────┘
```

### 4.2 交互流程

1. **页面初始状态**: 显示宠物选择器 (如果有多个档案)，照片区域显示一个「+」添加按钮
2. **选择照片**: 点击「+」打开图片选择器 (支持相册选择和拍照)
   - 支持多选，最多 5 张
   - 选择后显示缩略图预览
   - 每张预览图右上角有「×」按钮可移除
   - 如果已选 5 张，隐藏「+」按钮
3. **日期提取与设置**:
   - 选择照片后自动尝试提取 EXIF 日期
   - 按照片选择顺序，使用第一个成功提取到日期的值
   - 如果所有照片都没有 EXIF 日期信息，默认使用当天日期
   - 日期输入框始终可编辑，点击弹出日期选择器
4. **提交记录**: 点击「记录完成」按钮
   - 按钮需要同时满足: 已选择宠物 + 已选择至少 1 张照片
   - 提交时显示上传进度
   - 成功后弹出 SnackBar 提示「记录完成」
   - 页面重置: 清空已选照片，日期恢复为当天

### 4.3 EXIF 日期提取 (`utils/exif_helper.dart`)

```dart
import 'dart:io';
import 'package:exif/exif.dart';

class ExifHelper {
  /// 从图片文件提取拍摄日期
  /// 返回 null 表示无法提取
  static Future<DateTime?> extractDate(File imageFile) async {
    try {
      final bytes = await imageFile.readAsBytes();
      final data = await readExifFromBytes(bytes);

      if (data.isEmpty) return null;

      // 优先使用 DateTimeOriginal
      final dateStr = data['EXIF DateTimeOriginal']?.printable ??
                      data['EXIF DateTimeDigitized']?.printable ??
                      data['Image DateTime']?.printable;

      if (dateStr == null) return null;

      // EXIF 日期格式: "2024:01:15 10:30:00"
      final parts = dateStr.split(' ');
      if (parts.isEmpty) return null;
      final datePart = parts[0].replaceAll(':', '-');
      return DateTime.tryParse(datePart);
    } catch (_) {
      return null;
    }
  }

  /// 从多张照片中提取第一个有效日期
  static Future<DateTime?> extractFirstValidDate(List<File> files) async {
    for (final file in files) {
      final date = await extractDate(file);
      if (date != null) return date;
    }
    return null;
  }
}
```

### 4.4 照片选择与预览组件

```dart
// 使用 image_picker 包
final ImagePicker _picker = ImagePicker();

// 选择多张照片
Future<void> _pickImages() async {
  final remaining = 5 - _selectedImages.length;
  if (remaining <= 0) return;

  final List<XFile> images = await _picker.pickMultiImage(
    maxWidth: null,  // 保持原图
    maxHeight: null,
    imageQuality: null,
  );

  if (images.isNotEmpty) {
    final toAdd = images.take(remaining).toList();
    setState(() {
      _selectedImages.addAll(toAdd);
    });
    // 提取 EXIF 日期
    _updateDateFromExif();
  }
}
```

### 4.5 上传进度展示

上传多张照片时，显示进度对话框:

```
┌─────────────────────┐
│   正在上传照片...     │
│   ████████░░ 3/5    │
│                     │
│   请勿关闭页面       │
└─────────────────────┘
```

使用 Dio 的 `onSendProgress` 回调显示上传进度。

### 4.6 API 调用 (`services/photo_service.dart`)

```dart
class PhotoService {
  final ApiClient _apiClient;

  PhotoService(this._apiClient);

  Future<PhotoUploadResponse> uploadPhotos({
    required int petId,
    required List<File> files,
    required DateTime takenAt,
  }) async {
    final formData = FormData();

    for (final file in files) {
      formData.files.add(MapEntry(
        'files',
        await MultipartFile.fromFile(file.path),
      ));
    }

    formData.fields.add(MapEntry(
      'taken_at',
      '${takenAt.year}-${takenAt.month.toString().padLeft(2, '0')}-${takenAt.day.toString().padLeft(2, '0')}',
    ));

    final response = await _apiClient.dio.post(
      '/pets/$petId/photos',
      data: formData,
    );

    return PhotoUploadResponse.fromJson(response.data);
  }
}
```

---

## 5. 需要创建/修改的文件清单

### 后端
- `backend/app/services/image_recognition.py` - 宠物图片校验服务 (新建)
- `backend/app/services/storage.py` - MinIO 存储服务 (新建或补充)
- `backend/app/schemas/photo.py` - 照片 Schema (新建)
- `backend/app/api/v1/photos.py` - 照片路由，含宠物图片校验 (新建)
- `backend/app/api/v1/router.py` - 注册 photos 路由 (修改)
- `backend/requirements.txt` - 添加 `alibabacloud_imagerecog20190930` (修改)

### 前端
- `frontend/lib/models/photo.dart` - 照片数据模型 (新建)
- `frontend/lib/services/photo_service.dart` - 照片 API 服务 (新建)
- `frontend/lib/screens/record/record_screen.dart` - 记录页面 (实现)
- `frontend/lib/utils/exif_helper.dart` - EXIF 日期提取 (新建)
- `frontend/lib/widgets/photo_picker_grid.dart` - 照片选择预览组件 (新建)

---

## 6. 验收标准

- [ ] 后端 `POST /api/v1/pets/{id}/photos` 支持上传 1-5 张照片
- [ ] 后端正确验证文件类型 (JPEG/PNG/WEBP) 和大小 (<= 15MB)
- [ ] Flutter 在选择 HEIC/HEIF 时先转换为 JPEG 再上传
- [ ] 后端调用阿里云场景识别 API 校验图片是否包含宠物
- [ ] 上传非宠物图片时返回 400 错误: "未识别到宠物，请换一张图片试试吧！"
- [ ] 场景识别服务异常时放行上传，不阻塞正常流程
- [ ] 后端自动生成缩略图并存储到 MinIO
- [ ] 后端 `GET /api/v1/pets/{id}/photos` 分页返回照片列表
- [ ] 后端 `DELETE /api/v1/photos/{id}` 删除照片及 MinIO 文件
- [ ] Flutter 记录页面展示宠物选择器
- [ ] Flutter 可以从相册选择多张照片 (最多5张)
- [ ] Flutter 照片预览正确显示，可以删除单张
- [ ] Flutter 自动从 EXIF 提取日期并填入日期输入框
- [ ] Flutter 多张照片时使用第一个有效 EXIF 日期
- [ ] Flutter 无 EXIF 日期时默认为当天
- [ ] Flutter 日期输入框可以手动编辑
- [ ] Flutter 上传时显示进度
- [ ] Flutter 上传成功后弹出提示，页面重置
- [ ] 无宠物档案时提示用户先创建档案
- [ ] Flutter 上传非宠物图片时正确展示拒绝提示信息
