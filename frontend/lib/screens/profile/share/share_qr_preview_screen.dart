import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saver_gallery/saver_gallery.dart';

import '../../../config/theme.dart';
import '../../../widgets/share_qr_card.dart';

/// Full-screen preview that lets the owner save the share QR card as a
/// PNG in the system gallery. The card itself lives inside a
/// [RepaintBoundary] so we can snapshot the *rendered* widget (with
/// brand chrome, pet name, expiry, code) instead of dumping the bare
/// QR png — which is the whole point of this screen.
class ShareQrPreviewScreen extends StatefulWidget {
  final String code;
  final String petName;
  final DateTime expiresAt;

  const ShareQrPreviewScreen({
    super.key,
    required this.code,
    required this.petName,
    required this.expiresAt,
  });

  @override
  State<ShareQrPreviewScreen> createState() => _ShareQrPreviewScreenState();
}

class _ShareQrPreviewScreenState extends State<ShareQrPreviewScreen> {
  final GlobalKey _boundaryKey = GlobalKey();
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      final perm = await _ensureGalleryPermission();
      if (!perm) {
        if (!mounted) return;
        _toast('未授予保存到相册的权限');
        return;
      }

      final bytes = await _captureCard();
      if (bytes == null) {
        if (!mounted) return;
        _toast('截图失败，请重试');
        return;
      }

      final filename = 'dangdang_share_${widget.code}.png';
      final result = await SaverGallery.saveImage(
        bytes,
        fileName: filename,
        androidRelativePath: 'Pictures/DangDangDiary',
        skipIfExists: false,
      );
      if (!mounted) return;
      if (result.isSuccess) {
        _toast('已保存到相册');
      } else {
        final reason = result.errorMessage;
        _toast(
          (reason != null && reason.isNotEmpty) ? reason : '保存失败，请重试',
        );
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('[shareQrPreview] save failed: $e\n$st');
      if (!mounted) return;
      _toast('保存失败，请重试');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<Uint8List?> _captureCard() async {
    final ctx = _boundaryKey.currentContext;
    if (ctx == null) return null;
    final boundary = ctx.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return null;
    // pixelRatio 3 lands the saved PNG around 1080 dp wide, plenty
    // crisp for a 1080p phone display when the receiver pinches in.
    final image = await boundary.toImage(pixelRatio: 3);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<bool> _ensureGalleryPermission() async {
    // Android Q+ writes via MediaStore and doesn't actually prompt;
    // `Permission.storage` resolves to denied silently on those
    // versions, so we treat anything that isn't `permanentlyDenied`
    // as "let saver_gallery try". iOS asks for add-only.
    if (Theme.of(context).platform == TargetPlatform.iOS) {
      final status = await Permission.photosAddOnly.request();
      return status.isGranted || status.isLimited;
    }
    final status = await Permission.storage.request();
    return !status.isPermanentlyDenied;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('分享给好友')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            Center(
              child: RepaintBoundary(
                key: _boundaryKey,
                child: ShareQrCard(
                  code: widget.code,
                  petName: widget.petName,
                  expiresAt: widget.expiresAt,
                ),
              ),
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save_alt),
                label: Text(_saving ? '保存中...' : '保存到相册'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primaryColor,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              '保存后可在相册中分享给好友，对方扫一扫即可加入档案。',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
