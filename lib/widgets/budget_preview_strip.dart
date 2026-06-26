// P2.2.B — Pure presentation widget for the entry-time budget preview strip.
// Renders a single-line, animated strip that previews the post-entry budget
// state computed by previewAfterEntry() in budget_service.dart.
//
// Pure: no BuildContext-owned state, no setState, no SharedPreferences, no DB,
// no service calls. State ownership stays with the parent (_AddSheet /
// _EditSheet) — this widget receives a BudgetPreview and renders it.
//
// Animation contract:
//   • AnimatedSize handles the appear/disappear collapse when scope flips
//     to/from BudgetScope.none (the .none branch returns SizedBox.shrink()).
//   • AnimatedSwitcher cross-fades the inner content when severity tier or
//     amounts change. Keying by severity + projected ensures the switcher
//     animates on meaningful changes (tier flips, recomputed projections)
//     without thrashing on every keystroke that yields identical output.
//
// Color contract (matches BudgetHeroCard / BudgetStatusCard severity palette):
//   safe  → accent (passed in by parent — single source of truth for tint)
//   tight → amber  Color(0xFFF59E0B)
//   over  → red    Color(0xFFF43F5E)
//
// Typography: monetary values use JetBrainsMono (matches hero/status cards);
// labels use the ambient text theme.
//
// Layout contract (verbatim spacing system from neighboring cards):
//   margin LTRB 16 / 0 / 16 / 0
//   padding all 12
//   radius 12
//   bg = color.withOpacity(0.08)
//   border = color.withOpacity(0.20), width 1
//
// Scope label:
//   BudgetScope.category → "Category"
//   BudgetScope.monthly  → "Monthly"
//   BudgetScope.none     → strip is hidden (collapsed by AnimatedSize)
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../services/budget_service.dart';
import '../utils/formatters.dart';

class BudgetPreviewStrip extends StatelessWidget {
  final BudgetPreview preview;
  final String categoryName;
  final Color accent;
  const BudgetPreviewStrip({super.key, required this.preview, required this.categoryName, required this.accent});

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        transitionBuilder: (child, anim) => FadeTransition(
          opacity: anim,
          child: SizeTransition(sizeFactor: anim, axisAlignment: -1.0, child: child),
        ),
        child: preview.scope == BudgetScope.none
            ? const SizedBox.shrink(key: ValueKey('preview-none'))
            : _buildStrip(context),
      ),
    );
  }

  Widget _buildStrip(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final color = _colorFor(preview.severity, accent);
    final isCategory = preview.scope == BudgetScope.category;
    final overBy = preview.severity == BudgetSeverity.over ? preview.projected - preview.budget : 0.0;

    final String headline;
    final String? secondary;
    final IconData icon;
    switch (preview.severity) {
      case BudgetSeverity.over:
        icon = Icons.error_rounded;
        headline = isCategory
            ? '${fmtAmt(overBy)} over $categoryName budget'
            : '${fmtAmt(overBy)} over monthly budget';
        secondary = isCategory
            ? '${fmtAmt(preview.projected)} spent of ${fmtAmt(preview.budget)}'
            : null;
        break;
      case BudgetSeverity.tight:
        icon = Icons.warning_amber_rounded;
        headline = isCategory
            ? '$categoryName budget almost exhausted'
            : 'Monthly budget almost exhausted';
        secondary = '${fmtAmt(preview.remaining)} remaining';
        break;
      case BudgetSeverity.safe:
        icon = Icons.check_circle_rounded;
        headline = isCategory
            ? 'After this: ${fmtAmt(preview.remaining)} left in $categoryName'
            : '${fmtAmt(preview.remaining)} left this month';
        secondary = null;
        break;
    }

    return Container(
      key: ValueKey('preview-${preview.severity}-${preview.projected.toStringAsFixed(2)}'),
      margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: color.withOpacity(0.08),
        border: Border.all(color: color.withOpacity(0.20), width: 1),
      ),
      child: Row(children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                headline,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
              if (secondary != null) ...[
                const SizedBox(height: 2),
                Text(
                  secondary,
                  style: TextStyle(
                    fontSize: 11,
                    color: cs.onSurface.withOpacity(0.55),
                  ),
                ),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  static Color _colorFor(BudgetSeverity sev, Color accent) {
    switch (sev) {
      case BudgetSeverity.safe:
        return accent;
      case BudgetSeverity.tight:
        return const Color(0xFFF59E0B);
      case BudgetSeverity.over:
        return const Color(0xFFF43F5E);
    }
  }
}