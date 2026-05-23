import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../services/share_link.dart';

/// Full-screen QR scanner for sharing-codes.
///
/// Pops with the *normalised* 8-char share code on success, or with
/// `null` when the user cancels. Picking a non-当当日记 QR (a 公众号
/// follow card, a Wi-Fi password, a vCard, etc.) keeps the scanner
/// running but shows a one-shot SnackBar so the user knows we
/// actively rejected it instead of just failing to detect anything.
class ShareScanScreen extends StatefulWidget {
  const ShareScanScreen({super.key});

  @override
  State<ShareScanScreen> createState() => _ShareScanScreenState();
}

class _ShareScanScreenState extends State<ShareScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );

  // True while a `pop` is in flight or while we are showing a
  // "not 当当日记" toast. Prevents the scanner from spamming us as the
  // user keeps the camera pointed at the same code.
  bool _busy = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_busy) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final code = parseShareCode(raw);
      if (code != null) {
        _busy = true;
        Navigator.of(context).pop(code);
        return;
      }
      // Non-当当日记 QR: cool down for a couple of seconds so the
      // user has time to either move the camera or hit Cancel.
      _busy = true;
      _toast('这不是一张当当日记的分享码');
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) _busy = false;
      });
      return;
    }
  }

  Future<void> _pickFromGallery() async {
    if (_busy) return;
    _busy = true;
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(source: ImageSource.gallery);
      if (xfile == null || !mounted) return;
      final capture = await _controller.analyzeImage(xfile.path);
      if (!mounted) return;
      if (capture == null || capture.barcodes.isEmpty) {
        _toast('图片中没有识别到二维码');
        return;
      }
      for (final barcode in capture.barcodes) {
        final raw = barcode.rawValue;
        if (raw == null || raw.isEmpty) continue;
        final code = parseShareCode(raw);
        if (code != null) {
          Navigator.of(context).pop(code);
          return;
        }
      }
      _toast('这不是一张当当日记的分享码');
    } finally {
      // Camera flow keeps `_busy=true` only briefly via Future.delayed;
      // the gallery flow needs to reset synchronously after the pick.
      if (mounted) _busy = false;
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('扫描分享二维码')),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                MobileScanner(
                  controller: _controller,
                  onDetect: _onDetect,
                  fit: BoxFit.cover,
                ),
                // Subtle on-camera hint so the user knows what to do.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 16,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 32),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      '将二维码放入取景框内',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickFromGallery,
                      icon: Icon(Icons.photo_library_rounded),
                      label: const Text('从相册选择'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: Icon(Icons.close_rounded),
                      label: const Text('取消'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Convenience helper to identify a share code from a single picked
/// gallery image, without ever showing the live camera UI. Used by
/// the entry sheet's "从相册选择二维码" branch so the user doesn't have
/// to look at a black camera preview before being prompted to pick.
///
/// Returns the normalised 8-char code, or `null` when:
///   * the user cancelled the picker,
///   * no QR was detected in the image, or
///   * a QR was detected but did not parse as a 当当日记 share code.
/// SnackBar feedback is *not* shown here — caller controls UX.
Future<String?> pickShareCodeFromGallery() async {
  final picker = ImagePicker();
  final xfile = await picker.pickImage(source: ImageSource.gallery);
  if (xfile == null) return null;
  final controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );
  try {
    final capture = await controller.analyzeImage(xfile.path);
    if (capture == null || capture.barcodes.isEmpty) return null;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      final code = parseShareCode(raw);
      if (code != null) return code;
    }
    return null;
  } finally {
    await controller.dispose();
  }
}
