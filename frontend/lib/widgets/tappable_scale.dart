import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps [child] with a press-down scale animation + a light haptic
/// click on the *tap-down* edge (not on release — that's what feels
/// right on iOS / good Android apps).
///
/// Use for primary CTAs and any card / chip whose press deserves a
/// physical-feeling response. Skip for tiny icon buttons (they already
/// have Material ink) and for destructive confirmations (where a beat
/// of latency is desirable).
class TappableScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final Duration duration;
  final bool haptic;
  final HitTestBehavior behavior;

  const TappableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.96,
    this.duration = const Duration(milliseconds: 110),
    this.haptic = true,
    this.behavior = HitTestBehavior.opaque,
  });

  @override
  State<TappableScale> createState() => _TappableScaleState();
}

class _TappableScaleState extends State<TappableScale> {
  bool _down = false;

  void _setDown(bool v) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    if (_down == v) return;
    setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null && widget.onLongPress == null;
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: disabled
          ? null
          : (_) {
              _setDown(true);
              if (widget.haptic) HapticFeedback.selectionClick();
            },
      onTapCancel: disabled ? null : () => _setDown(false),
      onTapUp: disabled ? null : (_) => _setDown(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1.0,
        duration: widget.duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
