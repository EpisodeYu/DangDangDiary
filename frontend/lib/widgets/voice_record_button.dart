import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';

import '../config/theme.dart';

/// WeChat-style press-and-hold recorder button.
///
/// * Long press to start recording.
/// * Release to finish and hand the file to [onRecordComplete].
/// * Drag the finger upward (past [_cancelThreshold]) to cancel without
///   invoking the callback.
/// * Hard-capped at [_maxSeconds]; auto-stops (still emits the file).
///
/// Rendered as a compact pill at rest and a full-bleed overlay while
/// recording so the user gets obvious feedback on a small screen.
class VoiceRecordButton extends StatefulWidget {
  /// Invoked with the saved audio file after release. The parent is
  /// responsible for uploading / processing the bytes and for cleaning
  /// up the file (the widget doesn't delete it because the upload may
  /// still be in flight when the user's next interaction fires).
  final Future<void> Function(File audioFile) onRecordComplete;

  /// Optional hook for the parent to disable other UI (photo picker,
  /// submit button) while the user is talking.
  final VoidCallback? onRecordStart;
  final VoidCallback? onRecordCancel;

  /// Show/hide the button without unmounting it.
  final bool enabled;

  const VoiceRecordButton({
    super.key,
    required this.onRecordComplete,
    this.onRecordStart,
    this.onRecordCancel,
    this.enabled = true,
  });

  @override
  State<VoiceRecordButton> createState() => _VoiceRecordButtonState();
}

const int _maxSeconds = 30;
const double _cancelThreshold = 60; // logical px upward to trigger cancel

class _VoiceRecordButtonState extends State<VoiceRecordButton> {
  final AudioRecorder _recorder = AudioRecorder();

  bool _recording = false;
  bool _willCancel = false;
  double _dragOffsetY = 0; // cumulative upward drag (positive = up)
  int _elapsedSeconds = 0;
  double _amplitudeNorm = 0; // 0..1 for waveform pulse
  String? _activePath;
  Timer? _timer;
  StreamSubscription<Amplitude>? _ampSub;

  @override
  void dispose() {
    _timer?.cancel();
    _ampSub?.cancel();
    _recorder.dispose();
    super.dispose();
  }

  // --------------------------------------------------------------- UX

  @override
  Widget build(BuildContext context) {
    final disabled = !widget.enabled;
    return Stack(
      clipBehavior: Clip.none,
      alignment: Alignment.topCenter,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPressStart: disabled ? null : (_) => _startRecording(),
          onLongPressMoveUpdate: disabled ? null : _onDragUpdate,
          onLongPressEnd: disabled ? null : (_) => _stopRecording(cancelled: _willCancel),
          onLongPressCancel: disabled ? null : () => _stopRecording(cancelled: true),
          child: _buildButton(disabled),
        ),
        if (_recording)
          Positioned(
            top: -220,
            child: IgnorePointer(child: _buildHud()),
          ),
      ],
    );
  }

  Widget _buildButton(bool disabled) {
    final color = _recording
        ? (_willCancel ? AppTheme.errorColor : AppTheme.primaryColor)
        : (disabled ? Colors.grey.shade300 : AppTheme.primaryColor);
    final label = _recording
        ? (_willCancel ? '松开取消' : '松开发送')
        : '按住说话';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: double.infinity,
      height: 56,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(28),
        boxShadow: _recording
            ? [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: 18,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      alignment: Alignment.center,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            _recording ? Icons.mic : Icons.mic_none,
            color: Colors.white,
            size: 22,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  /// The "floating card" drawn above the button while recording.
  ///
  /// Shows: live waveform-ish pulse, elapsed seconds, and a big
  /// "slide up to cancel" hint that flips to a warning when the
  /// fingertip has crossed the cancel threshold.
  Widget _buildHud() {
    final hintColor = _willCancel ? AppTheme.errorColor : Colors.black87;
    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      color: Colors.white,
      child: Container(
        width: 220,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _WaveformPulse(intensity: _amplitudeNorm),
            const SizedBox(height: 10),
            Text(
              '${_elapsedSeconds}s / ${_maxSeconds}s',
              style: TextStyle(
                fontSize: 13,
                color: Colors.grey.shade600,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _willCancel ? Icons.close : Icons.keyboard_arrow_up,
                  size: 18,
                  color: hintColor,
                ),
                const SizedBox(width: 4),
                Text(
                  _willCancel ? '松开手指，取消发送' : '上滑取消',
                  style: TextStyle(
                    fontSize: 13,
                    color: hintColor,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ logic

  void _onDragUpdate(LongPressMoveUpdateDetails d) {
    // localOffsetFromOrigin.dy < 0 means user dragged up.
    final dy = -d.localOffsetFromOrigin.dy;
    final nextCancel = dy > _cancelThreshold;
    if (nextCancel != _willCancel || dy != _dragOffsetY) {
      setState(() {
        _dragOffsetY = dy;
        _willCancel = nextCancel;
      });
    }
  }

  Future<void> _startRecording() async {
    if (_recording) return;

    // Permission — `record` has its own hasPermission() that already
    // triggers the system prompt on Android/iOS, but permission_handler
    // is the shared path the rest of the app uses. Prefer the former
    // for consistency with the record package's internals.
    final granted = await _ensureMicPermission();
    if (!granted) {
      _showToast('需要麦克风权限才能录音');
      return;
    }

    final dir = await getTemporaryDirectory();
    final path =
        '${dir.path}/voice_${DateTime.now().millisecondsSinceEpoch}.m4a';

    try {
      await _recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          sampleRate: 16000, // match DashScope Paraformer expectation
          numChannels: 1,
          bitRate: 64000,
        ),
        path: path,
      );
    } catch (e) {
      _showToast('启动录音失败，请稍后重试');
      return;
    }

    _activePath = path;
    _elapsedSeconds = 0;
    _dragOffsetY = 0;
    _willCancel = false;
    _amplitudeNorm = 0;
    setState(() => _recording = true);
    widget.onRecordStart?.call();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_recording) return;
      setState(() => _elapsedSeconds += 1);
      if (_elapsedSeconds >= _maxSeconds) {
        _stopRecording(cancelled: false);
      }
    });

    _ampSub = _recorder
        .onAmplitudeChanged(const Duration(milliseconds: 120))
        .listen((amp) {
      // `amp.current` is in dBFS roughly in [-60, 0]; map to [0, 1].
      final db = amp.current;
      final norm = ((db + 60) / 60).clamp(0.0, 1.0);
      if (mounted && _recording) {
        setState(() => _amplitudeNorm = norm);
      }
    });
  }

  Future<void> _stopRecording({required bool cancelled}) async {
    if (!_recording) return;
    _recording = false;
    _timer?.cancel();
    _timer = null;
    await _ampSub?.cancel();
    _ampSub = null;

    String? path;
    try {
      path = await _recorder.stop();
    } catch (_) {
      path = _activePath;
    }

    final tookTooShort = _elapsedSeconds < 1;
    setState(() {
      _willCancel = false;
      _amplitudeNorm = 0;
    });

    if (cancelled || tookTooShort) {
      if (path != null) {
        try {
          await File(path).delete();
        } catch (_) {}
      }
      widget.onRecordCancel?.call();
      if (tookTooShort && !cancelled) {
        _showToast('说话时间太短');
      }
      return;
    }

    if (path == null) {
      _showToast('录音失败，请重试');
      return;
    }

    await widget.onRecordComplete(File(path));
  }

  Future<bool> _ensureMicPermission() async {
    final viaRecord = await _recorder.hasPermission();
    if (viaRecord) return true;
    final status = await Permission.microphone.request();
    return status.isGranted;
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
      );
  }
}

// --------------------------------------------------------- waveform

class _WaveformPulse extends StatelessWidget {
  /// 0..1 — live microphone amplitude.
  final double intensity;

  const _WaveformPulse({required this.intensity});

  @override
  Widget build(BuildContext context) {
    // A 5-bar crude VU meter. Each bar's height is gated by how close
    // `intensity` is to the bar's threshold; the result looks like a
    // responsive bouncing level meter without needing a CustomPaint.
    final bars = List.generate(5, (i) {
      final gate = (i + 1) / 5;
      final lit = intensity >= gate * 0.4;
      final h = lit ? (10 + 24 * (intensity - gate * 0.4).clamp(0, 1)) : 6.0;
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        width: 6,
        height: h.toDouble(),
        decoration: BoxDecoration(
          color: AppTheme.primaryColor,
          borderRadius: BorderRadius.circular(3),
        ),
      );
    });
    return SizedBox(
      height: 40,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: bars,
      ),
    );
  }
}
