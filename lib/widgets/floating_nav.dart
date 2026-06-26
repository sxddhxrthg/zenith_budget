// P1.5.F.3 — Pure presentation widget extracted verbatim from main.dart
// (_ShellState.build, the floating pill nav inside the bottom Stack).
//
// No behavior changes. Pixel-, animation-, color-, haptic-, spacing-,
// and icon-order-identical to the original inline block.
//
// Scope: the inner Container only (the pill itself, NOT the surrounding
// Positioned). State ownership stays with _ShellState — the parent still
// owns `_tab`, computes `bottomPad`, and wraps this widget in Positioned.
// This preserves the Stack layout structure exactly and keeps
// "don't change bottom padding behavior" honest.
//
// Icon order (verbatim, do not reorder):
//   home_rounded, swap_vert_rounded, pie_chart_rounded,
//   analytics_rounded, settings_rounded
//
// Selection visual (verbatim):
//   AnimatedContainer 200ms, padding H16/V8, radius 20,
//   selected bg = accent.withOpacity(0.12), icon size 24,
//   selected icon = accent, unselected = onSurface.withOpacity(0.35).
//
// Haptic: HapticFeedback.lightImpact() on tap — same as original.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class FloatingNav extends StatelessWidget {
  final int currentIndex;
  final Color accent;
  final ValueChanged<int> onSelect;
  const FloatingNav({super.key, required this.currentIndex, required this.accent, required this.onSelect});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(28), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 24, offset: const Offset(0, 4))]),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: List.generate(5, (i) { final icons = [Icons.home_rounded, Icons.swap_vert_rounded, Icons.pie_chart_rounded, Icons.analytics_rounded, Icons.settings_rounded]; final sel = currentIndex == i;
          return GestureDetector(onTap: () { HapticFeedback.lightImpact(); onSelect(i); }, behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(duration: const Duration(milliseconds: 200), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: sel ? accent.withOpacity(0.12) : Colors.transparent),
              child: Icon(icons[i], size: 24, color: sel ? accent : cs.onSurface.withOpacity(0.35)))); }))));
  }
}