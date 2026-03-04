import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

class DnaCLogo extends StatelessWidget {
  const DnaCLogo({
    super.key,
    this.size = 34,
    this.primary = const Color(0xFF7CD8FF),
    this.secondary = const Color(0xFF2EB9D8),
    this.highlight = const Color(0xFFFFB36D),
  });

  final double size;
  final Color primary;
  final Color secondary;
  final Color highlight;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _DnaCLogoPainter(
          primary: primary,
          secondary: secondary,
          highlight: highlight,
        ),
      ),
    );
  }
}

class _DnaCLogoPainter extends CustomPainter {
  _DnaCLogoPainter({
    required this.primary,
    required this.secondary,
    required this.highlight,
  });

  final Color primary;
  final Color secondary;
  final Color highlight;

  @override
  void paint(Canvas canvas, Size size) {
    final side = size.shortestSide;
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = side * 0.44;
    final innerRadius = side * 0.29;
    final start = _degToRad(42);
    final sweep = _degToRad(276);

    final glowPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = side * 0.17
      ..color = primary.withValues(alpha: 0.12);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: outerRadius - side * 0.01),
      start,
      sweep,
      false,
      glowPaint,
    );

    final outerStrandPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = side * 0.11
      ..shader = SweepGradient(
        startAngle: start,
        endAngle: start + sweep,
        colors: <Color>[primary, secondary, primary],
        stops: const <double>[0.0, 0.55, 1.0],
        transform: const GradientRotation(-math.pi / 2),
      ).createShader(Rect.fromCircle(center: center, radius: outerRadius));

    final innerStrandPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeWidth = side * 0.06
      ..color = Colors.white.withValues(alpha: 0.93);

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: outerRadius),
      start,
      sweep,
      false,
      outerStrandPaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: innerRadius),
      start + _degToRad(2),
      sweep - _degToRad(4),
      false,
      innerStrandPaint,
    );

    const linkCount = 9;
    for (var i = 0; i < linkCount; i++) {
      final t = i / (linkCount - 1);
      final angle = start + sweep * t;
      final twist = math.sin(t * math.pi * 2);
      final fromRadius = lerpDouble(
        innerRadius + side * 0.01,
        outerRadius - side * 0.04,
        (twist + 1) * 0.5,
      )!;
      final toRadius = lerpDouble(
        innerRadius + side * 0.06,
        outerRadius - side * 0.01,
        (twist + 1) * 0.5,
      )!;

      final fromPoint = _point(center, fromRadius, angle);
      final toPoint = _point(center, toRadius, angle);

      final rungPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = side * (i.isEven ? 0.024 : 0.017)
        ..color = (i.isEven ? highlight : primary).withValues(alpha: 0.92);

      canvas.drawLine(fromPoint, toPoint, rungPaint);

      final beadPaint = Paint()
        ..style = PaintingStyle.fill
        ..color = (i.isEven ? highlight : Colors.white).withValues(alpha: 0.96);
      final beadRadius = side * (i.isEven ? 0.024 : 0.02);
      canvas.drawCircle(i.isEven ? fromPoint : toPoint, beadRadius, beadPaint);
    }

    final tipPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = highlight.withValues(alpha: 0.95);
    canvas.drawCircle(
        _point(center, outerRadius, start), side * 0.04, tipPaint);
    canvas.drawCircle(
      _point(center, outerRadius, start + sweep),
      side * 0.04,
      tipPaint,
    );
  }

  Offset _point(Offset center, double radius, double angle) {
    return Offset(
      center.dx + math.cos(angle) * radius,
      center.dy + math.sin(angle) * radius,
    );
  }

  double _degToRad(double degrees) => degrees * math.pi / 180;

  @override
  bool shouldRepaint(covariant _DnaCLogoPainter oldDelegate) {
    return oldDelegate.primary != primary ||
        oldDelegate.secondary != secondary ||
        oldDelegate.highlight != highlight;
  }
}
