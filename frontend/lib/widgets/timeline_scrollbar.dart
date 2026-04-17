import 'package:flutter/material.dart';

import '../config/theme.dart';
import '../models/timeline.dart';

/// Right-side month scrubber for the timeline.
///
/// The strip shows one tick per month (newest at top, oldest at bottom).
/// Tick length scales with the month's photo count so the user gets a
/// rough density cue.
///
/// Drag anywhere on the strip to jump. Release triggers [onJump] with the
/// targeted month key (e.g. `"2024-01"`).
class TimelineScrollbar extends StatefulWidget {
  final List<DateDistribution> months;
  final String? activeMonth;
  final ValueChanged<String> onJump;

  const TimelineScrollbar({
    super.key,
    required this.months,
    required this.activeMonth,
    required this.onJump,
  });

  @override
  State<TimelineScrollbar> createState() => _TimelineScrollbarState();
}

class _TimelineScrollbarState extends State<TimelineScrollbar> {
  int? _hoverIndex;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    if (widget.months.isEmpty) return const SizedBox.shrink();

    return LayoutBuilder(builder: (context, constraints) {
      final height = constraints.maxHeight;
      return SizedBox(
        width: 56,
        height: height,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned(
              right: 8,
              top: 12,
              bottom: 12,
              width: 24,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragStart: (d) => _onDragStart(d.localPosition, height),
                onVerticalDragUpdate: (d) =>
                    _onDragUpdate(d.localPosition, height),
                onVerticalDragEnd: (_) => _onDragEnd(),
                onVerticalDragCancel: _onDragEnd,
                onTapDown: (d) => _onDragStart(d.localPosition, height),
                onTapUp: (_) => _onDragEnd(),
                child: CustomPaint(
                  painter: _TrackPainter(
                    months: widget.months,
                    activeMonth: widget.activeMonth,
                    hoverIndex: _hoverIndex,
                  ),
                ),
              ),
            ),
            if (_dragging && _hoverIndex != null)
              Positioned(
                right: 40,
                top: _bubbleTop(height),
                child: _Bubble(label: widget.months[_hoverIndex!].label),
              ),
          ],
        ),
      );
    });
  }

  double _bubbleTop(double height) {
    final idx = _hoverIndex ?? 0;
    final trackHeight = height - 24; // padding on both sides of track
    final step = trackHeight / widget.months.length;
    return 12 + idx * step - 14;
  }

  int _indexFor(double dy, double height) {
    final trackHeight = height - 24;
    final localY = (dy - 0).clamp(0.0, trackHeight);
    final idx = (localY / trackHeight * widget.months.length).floor();
    return idx.clamp(0, widget.months.length - 1);
  }

  void _onDragStart(Offset p, double h) {
    setState(() {
      _dragging = true;
      _hoverIndex = _indexFor(p.dy, h);
    });
  }

  void _onDragUpdate(Offset p, double h) {
    setState(() {
      _hoverIndex = _indexFor(p.dy, h);
    });
  }

  void _onDragEnd() {
    final idx = _hoverIndex;
    setState(() {
      _dragging = false;
    });
    if (idx != null) {
      widget.onJump(widget.months[idx].date);
    }
  }
}

class _TrackPainter extends CustomPainter {
  final List<DateDistribution> months;
  final String? activeMonth;
  final int? hoverIndex;

  _TrackPainter({
    required this.months,
    required this.activeMonth,
    required this.hoverIndex,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paintBg = Paint()
      ..color = AppTheme.textSecondary.withValues(alpha: 0.15)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(size.width / 2, 0),
      Offset(size.width / 2, size.height),
      paintBg,
    );

    if (months.isEmpty) return;

    // Max count for width scaling.
    final maxCount = months.map((m) => m.count).reduce((a, b) => a > b ? a : b);

    final step = size.height / months.length;
    for (var i = 0; i < months.length; i++) {
      final m = months[i];
      final y = i * step + step / 2;
      final lenRatio = maxCount == 0 ? 0.2 : (m.count / maxCount);
      final halfLen = 4 + 8 * lenRatio;

      final isActive = m.date == activeMonth;
      final isHover = hoverIndex == i;
      final color = isHover
          ? AppTheme.primaryColor
          : (isActive
              ? AppTheme.primaryColor.withValues(alpha: 0.85)
              : AppTheme.textSecondary.withValues(alpha: 0.55));
      final paint = Paint()
        ..color = color
        ..strokeWidth = isActive || isHover ? 2.2 : 1.4;
      canvas.drawLine(
        Offset(size.width / 2 - halfLen, y),
        Offset(size.width / 2 + halfLen, y),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _TrackPainter old) {
    return old.months != months ||
        old.activeMonth != activeMonth ||
        old.hoverIndex != hoverIndex;
  }
}

class _Bubble extends StatelessWidget {
  final String label;
  const _Bubble({required this.label});

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 3,
      color: AppTheme.primaryColor,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}
