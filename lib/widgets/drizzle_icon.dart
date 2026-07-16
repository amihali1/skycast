import 'package:flutter/material.dart';

/// Custom drizzle glyph: an open, upright umbrella with a few light drops
/// falling onto the canopy. Distinct from [Icons.water_drop] (rain) and
/// deliberately sparse — three small dots read as drizzle, not a shower.
/// (Drawn from scratch: the stock [Icons.umbrella] glyph is a *closed*
/// umbrella and reads as anything but weather.)
class DrizzleIcon extends StatelessWidget {
  const DrizzleIcon({super.key, required this.size, required this.color});

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _DrizzlePainter(color),
      );
}

class _DrizzlePainter extends CustomPainter {
  _DrizzlePainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final fill = Paint()..color = color;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.07
      ..strokeCap = StrokeCap.round;

    // Canopy: dome with a scalloped lower edge (fabric rises between the
    // three rib points).
    final canopy = Path()
      ..moveTo(s * 0.10, s * 0.60)
      ..quadraticBezierTo(s * 0.10, s * 0.26, s * 0.50, s * 0.26)
      ..quadraticBezierTo(s * 0.90, s * 0.26, s * 0.90, s * 0.60)
      ..quadraticBezierTo(s * 0.77, s * 0.53, s * 0.635, s * 0.60)
      ..quadraticBezierTo(s * 0.50, s * 0.53, s * 0.365, s * 0.60)
      ..quadraticBezierTo(s * 0.23, s * 0.53, s * 0.10, s * 0.60)
      ..close();
    canvas.drawPath(canopy, fill);

    // Pole with a J-hook handle.
    final pole = Path()
      ..moveTo(s * 0.50, s * 0.60)
      ..lineTo(s * 0.50, s * 0.84)
      ..arcToPoint(
        Offset(s * 0.36, s * 0.84),
        radius: Radius.circular(s * 0.07),
        clockwise: true,
      );
    canvas.drawPath(pole, stroke);

    // Light drops falling onto the canopy, staggered so they read as
    // falling rather than as a decorative row.
    final r = s * 0.05;
    for (final (fx, fy) in [(0.22, 0.10), (0.50, 0.02), (0.78, 0.09)]) {
      canvas.drawCircle(Offset(s * fx, s * fy + r), r, fill);
    }
  }

  @override
  bool shouldRepaint(_DrizzlePainter oldDelegate) =>
      oldDelegate.color != color;
}
