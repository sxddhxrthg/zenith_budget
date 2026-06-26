// P1.5.F.4 — Pure presentation widget extracted verbatim from main.dart.
// No behavior changes. Pixel-, color-, opacity-, typography-, and
// spacing-identical to the two originals:
//   • Home insight card           (~L572)  — compact:  no title, Row layout
//   • Stats "AI Overview" card    (~L1353) — expanded: title,   Column layout
//
// Both share the accent-tinted shell:
//   margin LTRB 16 / top / 16 / 0
//   color  = accent.withOpacity(0.06)
//   body   = fontSize 11, cs.onSurface.withOpacity(0.65)
//
// The compact / expanded variants differ ONLY in the constants below — every
// value is taken straight from the original inline blocks, not "rounded" or
// unified. title == null selects compact; title != null selects expanded.
//
//   compact  : margin top 10, padding 12, radius 12, emoji 14, body height 1.4
//   expanded : margin top 14, padding 14, radius 14, emoji 16, body height 1.5
//              title style = fontSize 13, w700, color accent
//
// State ownership stays with the parent — body text is computed by the
// caller (homeInsight / statsInsight via _ins() / _ai()) and passed in.
import 'package:flutter/material.dart';

class InsightCard extends StatelessWidget {
  final Color accent;
  final String emoji;
  final String? title;
  final String body;
  const InsightCard({super.key, required this.accent, required this.emoji, this.title, required this.body});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final hasTitle = title != null;
    return Container(
      margin: EdgeInsets.fromLTRB(16, hasTitle ? 14 : 10, 16, 0),
      padding: EdgeInsets.all(hasTitle ? 14 : 12),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(hasTitle ? 14 : 12), color: accent.withOpacity(0.06)),
      child: hasTitle
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Text(emoji, style: const TextStyle(fontSize: 16)), const SizedBox(width: 8), Text(title!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent))]),
            const SizedBox(height: 8),
            Text(body, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.65), height: 1.5)),
          ])
        : Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(emoji, style: const TextStyle(fontSize: 14)),
            const SizedBox(width: 8),
            Expanded(child: Text(body, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.65), height: 1.4))),
          ]),
    );
  }
}