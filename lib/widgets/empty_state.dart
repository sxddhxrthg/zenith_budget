// P1.5.F.2 — Pure presentation widget extracted verbatim from main.dart.
// No behavior changes. Pixel-, spacing-, typography-, and opacity-identical
// to the originals (Home empty state @ ~L579 and Activity empty state @ ~L683).
//
// Layout contract (verbatim from both originals):
//   Padding(EdgeInsets.fromLTRB(32, 48, 32, 32)) > Column(children: [
//     Icon(icon, size: 48, color: cs.onSurface.withOpacity(0.12)),
//     SizedBox(height: 16),
//     Text(title,  fontSize: 16, w600,  color: cs.onSurface.withOpacity(0.4)),
//     SizedBox(height: 6),
//     Text(subtitle, textAlign: center, fontSize: 13, color: cs.onSurface.withOpacity(0.25)),
//   ])
//
// Subtitle preserves embedded newlines (e.g. 'line one\nline two') because
// callers pass them in raw — Text() honors \n as a soft break the same way
// the inline originals did.
import 'package:flutter/material.dart';

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const EmptyState({super.key, required this.icon, required this.title, required this.subtitle});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(padding: const EdgeInsets.fromLTRB(32, 48, 32, 32), child: Column(children: [
      Icon(icon, size: 48, color: cs.onSurface.withOpacity(0.12)),
      const SizedBox(height: 16),
      Text(title, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.4))),
      const SizedBox(height: 6),
      Text(subtitle, textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.25))),
    ]));
  }
}