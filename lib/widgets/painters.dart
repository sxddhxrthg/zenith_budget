import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../models/category.dart';

class PiePainter extends CustomPainter {
  final List<MapEntry<Cat, double>> data; final double total; final Color bg;
  PiePainter(this.data, this.total, this.bg);
  @override void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2); final r = size.width / 2 - 2; double a = -math.pi / 2;
    for (var e in data) { final sw = total > 0 ? (e.value / total) * 2 * math.pi : 0.0; canvas.drawArc(Rect.fromCircle(center: c, radius: r), a, sw, true, Paint()..color = e.key.color); a += sw; }
    canvas.drawCircle(c, r * 0.55, Paint()..color = bg);
  }
  @override bool shouldRepaint(covariant CustomPainter o) => true;
}

class TrendPainter extends CustomPainter {
  final List<double> pts; final Color color;
  TrendPainter(this.pts, this.color);
  @override void paint(Canvas canvas, Size size) {
    if (pts.length < 2) return; final mx = pts.reduce(math.max); if (mx == 0) return;
    final lp = Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    final fp = Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withOpacity(0.25), color.withOpacity(0.0)]).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    final gp = Paint()..color = color.withOpacity(0.06)..strokeWidth = 0.5;
    for (int i = 1; i < 4; i++) canvas.drawLine(Offset(0, size.height * i / 4), Offset(size.width, size.height * i / 4), gp);
    final path = Path(); final fill = Path();
    for (int i = 0; i < pts.length; i++) {
      final x = size.width * i / (pts.length - 1); final y = size.height * 0.92 - (pts[i] / mx * size.height * 0.85);
      if (i == 0) { path.moveTo(x, y); fill.moveTo(x, size.height); fill.lineTo(x, y); } else { path.lineTo(x, y); fill.lineTo(x, y); }
      if (i == pts.length - 1) canvas.drawCircle(Offset(x, y), 3.5, Paint()..color = color);
    }
    fill.lineTo(size.width, size.height); fill.close();
    canvas.drawPath(fill, fp); canvas.drawPath(path, lp);
    final step = pts.length > 15 ? 5 : pts.length > 7 ? 3 : 1;
    for (int i = 0; i < pts.length; i += step) {
      final x = size.width * i / (pts.length - 1);
      final tp = TextPainter(text: TextSpan(text: '${i + 1}', style: TextStyle(fontSize: 7, color: color.withOpacity(0.35))), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, size.height + 2));
    }
  }
  @override bool shouldRepaint(covariant CustomPainter o) => true;
}
