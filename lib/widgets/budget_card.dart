// P1.5.F.1 — Pure presentation widgets extracted verbatim from main.dart.
// No behavior changes. Pixel-, animation-, color-, and haptic-identical to
// the originals. State ownership stays with the parent (Home / BudgetsTab).
//
// Both widgets receive (monthBud, tExp) and compute their internal derived
// values using the exact same formulas that were inline at the call sites
// (pct, daysLeft, overBudget, left, dailyAllow, budgetPerDay, dailyColor for
// the hero; dim, dp, dl, pctUsed, da, proj, pctMonth, isOver, isAtRisk,
// paceColor, paceLabel, paceIcon for the status card). Formulas are kept
// verbatim — no algebraic simplification, even where the moved scope would
// permit it — so the diff is purely "extracted, not changed".
//
// BudgetHeroCard — Home tab hero. Gradient card with progress bar, daily
// allowance, and empty-state CTA when no budget is set. Both branches
// (monthBud > 0 / not) handled internally; render is unconditional.
//
// BudgetStatusCard — Budgets tab pace card. Surface-colored card with pace
// indicator, progress bar, spent/budget row, projection. Gated externally
// at the call site with `if (monthBud > 0) ...` so the widget assumes
// monthBud > 0 — same contract as the original inline block.
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../utils/formatters.dart';

class BudgetHeroCard extends StatelessWidget {
  final Color accent;
  final int monthBud;
  final double tExp;
  final VoidCallback onTap;
  const BudgetHeroCard({super.key, required this.accent, required this.monthBud, required this.tExp, required this.onTap});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = monthBud > 0 ? (tExp / monthBud).clamp(0.0, 1.0) : 0.0;
    final daysLeft = DateUtils.getDaysInMonth(DateTime.now().year, DateTime.now().month) - DateTime.now().day;
    final overBudget = monthBud > 0 && tExp > monthBud;
    final left = overBudget ? 0.0 : (monthBud - tExp).clamp(0.0, double.infinity);
    final dailyAllow = daysLeft > 0 && monthBud > 0 && !overBudget ? left / daysLeft : 0.0;
    // Daily allowance color: red if over, amber if tight (< 20% of budget/day), green otherwise
    final budgetPerDay = monthBud > 0 && daysLeft > 0 ? monthBud / DateUtils.getDaysInMonth(DateTime.now().year, DateTime.now().month) : 0.0;
    final dailyColor = overBudget
        ? const Color(0xFFF43F5E)
        : (dailyAllow > 0 && budgetPerDay > 0 && dailyAllow < budgetPerDay * 0.2)
            ? const Color(0xFFF59E0B)
            : const Color(0xFF22C55E);
    return GestureDetector(onTap: onTap, child: Container(margin: const EdgeInsets.fromLTRB(16, 12, 16, 0), padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: LinearGradient(colors: [accent.withOpacity(0.10), Colors.purple.withOpacity(0.04)])),
      child: monthBud > 0
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('MONTHLY BUDGET', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4), letterSpacing: 1.5, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            Text(fmtAmt(left), style: GoogleFonts.jetBrainsMono(fontSize: 28, fontWeight: FontWeight.w800, color: pct > 0.9 ? const Color(0xFFF43F5E) : cs.onSurface)),
            Text('left of ${fmtInt(monthBud)}', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4))),
            const SizedBox(height: 14),
            TweenAnimationBuilder<double>(tween: Tween(begin: 0, end: pct), duration: const Duration(milliseconds: 1200), curve: Curves.easeOutCubic,
              builder: (_, v, __) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(value: v, minHeight: 8, backgroundColor: cs.outline.withOpacity(0.08), valueColor: AlwaysStoppedAnimation(v > 0.9 ? const Color(0xFFF43F5E) : accent))),
                const SizedBox(height: 8),
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Text('${(v * 100).round()}% used', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))),
                  if (overBudget)
                    Text('${fmtAmt(tExp - monthBud)} over budget', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFFF43F5E)))
                  else if (daysLeft > 0 && monthBud > 0)
                    Text('${fmtAmt(dailyAllow)}/day · $daysLeft days left', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: dailyColor))])]))])
        : Column(children: [
            const SizedBox(height: 8),
            Icon(Icons.account_balance_wallet_rounded, size: 32, color: accent.withOpacity(0.5)),
            const SizedBox(height: 10),
            Text('Set your monthly budget', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
            const SizedBox(height: 4),
            Text('Tap to get started', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4))),
            const SizedBox(height: 8)])));
  }
}

class BudgetStatusCard extends StatelessWidget {
  final int monthBud;
  final double tExp;
  const BudgetStatusCard({super.key, required this.monthBud, required this.tExp});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme; final n = DateTime.now();
    final dim = DateUtils.getDaysInMonth(n.year, n.month);
    final dp = n.day; final dl = dim - dp;
    final pctUsed = monthBud > 0 ? (tExp / monthBud).clamp(0.0, 1.0) : 0.0;
    final da = dp > 0 && tExp > 0 ? tExp / dp : 0.0;
    final proj = da * dim;
    // Pace: compare % budget used vs % of month elapsed
    final pctMonth = dp / dim;
    final isOver = tExp > monthBud && monthBud > 0;
    final isAtRisk = !isOver && monthBud > 0 && pctUsed > pctMonth + 0.1;
    final paceColor = isOver ? const Color(0xFFF43F5E) : isAtRisk ? const Color(0xFFF59E0B) : const Color(0xFF22C55E);
    final paceLabel = isOver ? 'Over Budget' : isAtRisk ? 'At Risk' : 'On Track';
    final paceIcon = isOver ? '🔴' : isAtRisk ? '🟡' : '🟢';
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: cs.surface),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(paceIcon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Text(paceLabel, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: paceColor)),
          const Spacer(),
          Text('Day $dp of $dim', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))),
        ]),
        const SizedBox(height: 10),
        ClipRRect(borderRadius: BorderRadius.circular(4), child: LinearProgressIndicator(
          value: pctUsed,
          minHeight: 6,
          backgroundColor: cs.outline.withOpacity(0.1),
          valueColor: AlwaysStoppedAnimation(paceColor),
        )),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('${fmtAmt(tExp)} spent', style: GoogleFonts.jetBrainsMono(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface)),
          Text('${fmtInt(monthBud)} budget', style: GoogleFonts.jetBrainsMono(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.4))),
        ]),
        const SizedBox(height: 6),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          if (!isOver && dl > 0)
            Text('${fmtAmt((monthBud - tExp) / dl)}/day remaining', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.5)))
          else if (isOver)
            Text('${fmtAmt(tExp - monthBud)} over budget', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Color(0xFFF43F5E)))
          else
            const SizedBox.shrink(),
          if (da > 0) Text('Projected: ${fmtAmt(proj)}', style: TextStyle(fontSize: 11, color: proj > monthBud ? const Color(0xFFF43F5E) : cs.onSurface.withOpacity(0.4))),
        ]),
      ]),
    );
  }
}