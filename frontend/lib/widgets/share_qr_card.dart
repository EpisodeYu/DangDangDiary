import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../config/theme.dart';
import '../services/share_link.dart';

/// Square-ish printable card containing the share QR plus brand chrome.
///
/// The widget is sized for *layout*: 360 dp wide, height-by-content. The
/// caller wraps it in a `RepaintBoundary` and snapshots via
/// `RenderRepaintBoundary.toImage(pixelRatio: 3)` to produce a ~1080 dp
/// PNG suitable for saving to the system gallery.
///
/// Layout deliberately mirrors common IM card designs (logo header →
/// invitation copy → QR → footer with code + expiry) so it looks
/// familiar when forwarded inside WeChat / QQ.
class ShareQrCard extends StatelessWidget {
  final String code;
  final String petName;
  final DateTime expiresAt;

  const ShareQrCard({
    super.key,
    required this.code,
    required this.petName,
    required this.expiresAt,
  });

  @override
  Widget build(BuildContext context) {
    final url = buildShareUrl(code);
    return Container(
      width: 360,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              SvgPicture.asset(
                'assets/brand/logo.svg',
                width: 40,
                height: 40,
              ),
              const SizedBox(width: 10),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'DangDangDiary',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      '当当日记',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Divider(height: 1),
          const SizedBox(height: 20),
          Text(
            '扫码加入 $petName 的档案，\n一起记录它的成长。',
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 14,
              height: 1.5,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade200),
            ),
            child: QrImageView(
              data: url,
              version: QrVersions.auto,
              size: 240,
              backgroundColor: Colors.white,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            '分享码  ${_spaced(code)}',
            style: const TextStyle(
              fontSize: 18,
              letterSpacing: 4,
              fontFamily: 'monospace',
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '有效期至：${_formatExpiry(expiresAt)}',
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  String _spaced(String s) {
    // Render "ABCD1234" as "A B C D 1 2 3 4" for at-a-glance readability
    // when someone is forced to type it in manually.
    return s.split('').join(' ');
  }

  String _formatExpiry(DateTime d) {
    final local = d.toLocal();
    return '${local.year}-${_pad(local.month)}-${_pad(local.day)} '
        '${_pad(local.hour)}:${_pad(local.minute)}';
  }

  String _pad(int v) => v.toString().padLeft(2, '0');
}
