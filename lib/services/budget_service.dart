// P3.1.D — Pure budget math extracted verbatim from main.dart. No behavior
// changes. These functions:
//   • take pre-loaded data as arguments
//   • have no BuildContext, no State, no setState, no SharedPreferences, no DB writes
//   • are deterministic over their inputs
//
// Scope is deliberately small: only the month-scoped income/expense total
// helper that powers tExp/tInc and the projections downstream. Category
// budget math and per-category urgency colors remain inline in their build
// methods until those widgets themselves are extracted in a later phase.
import '../models/transaction.dart';

// Sum of `type`-typed transactions in the calendar month of [ref].
// Mirrors the inline behavior of the historical tExp/tInc getters exactly:
// year + month equality, no day component, no day-only projection.
double monthlyTotal(List<Txn> txns, String type, DateTime ref) =>
    txns.where((t) => t.type == type && t.date.year == ref.year && t.date.month == ref.month).fold(0.0, (s, t) => s + t.amount);

// P2.2.A — Budget Preview value object + pure preview engine.
// Pure: no BuildContext, no State, no setState, no SharedPreferences, no DB writes.
// Decides, for a candidate (or edited) expense, whether projected spend after this
// entry would land safe / tight / over against the most specific applicable budget.
//
// Scope precedence: a category budget on the candidate's category wins over the
// monthly budget. If neither is set, scope is none and callers should render
// nothing. Income entries always return BudgetPreview.none — budgets gate
// expenses only.
//
// Edit semantics: pass excludeTxnId so the row being edited is removed from the
// "current spent" baseline before the candidate's amount is added back in. This
// makes amount changes, category switches, and date changes all correct without
// any special-casing at the call site:
//   • amount change      → old excluded, new amount summed in
//   • category switch    → old row excluded entirely; new category determines scope
//   • date change        → currentSpent is recomputed against the candidate's
//                          target month (date.year/date.month), so backdating
//                          previews against that month, not "now"
//
// Severity thresholds mirror the hero card's existing 90% red boundary:
//   over  : projected > budget
//   tight : projected > budget * 0.9   (and ≤ budget)
//   safe  : otherwise
// Thresholds are only meaningful when scope != none; the .none sentinel keeps
// severity = safe so callers that ignore scope don't get false alarms.

enum BudgetScope { category, monthly, none }
enum BudgetSeverity { safe, tight, over }

class BudgetPreview {
  final BudgetScope scope;
  final BudgetSeverity severity;
  final double budget;        // effective budget for this scope; 0 if scope=none
  final double currentSpent;  // month-scoped spend before this entry (post-exclude)
  final double projected;     // currentSpent + amount
  final double remaining;     // budget - projected (can be negative)
  final double pct;           // projected / budget; 0 if scope=none
  const BudgetPreview({
    required this.scope,
    required this.severity,
    required this.budget,
    required this.currentSpent,
    required this.projected,
    required this.remaining,
    required this.pct,
  });
  static const none = BudgetPreview(
    scope: BudgetScope.none,
    severity: BudgetSeverity.safe,
    budget: 0, currentSpent: 0, projected: 0, remaining: 0, pct: 0,
  );
}

BudgetPreview previewAfterEntry({
  required String type,
  required double amount,
  required String categoryId,
  required DateTime date,
  required List<Txn> txns,
  required int monthBud,
  required Map<String, int> categoryBudgets,
  String? excludeTxnId,
}) {
  if (type != 'expense') return BudgetPreview.none;

  final catBud = categoryBudgets[categoryId] ?? 0;
  final BudgetScope scope = catBud > 0
      ? BudgetScope.category
      : (monthBud > 0 ? BudgetScope.monthly : BudgetScope.none);
  if (scope == BudgetScope.none) return BudgetPreview.none;

  final budget = (scope == BudgetScope.category ? catBud : monthBud).toDouble();

  double currentSpent = 0;
  for (final t in txns) {
    if (t.type != 'expense') continue;
    if (t.date.year != date.year || t.date.month != date.month) continue;
    if (excludeTxnId != null && t.id == excludeTxnId) continue;
    if (scope == BudgetScope.category && t.category != categoryId) continue;
    currentSpent += t.amount;
  }

  final projected = currentSpent + amount;
  final remaining = budget - projected;
  final pct = projected / budget;
  final BudgetSeverity severity = projected > budget
      ? BudgetSeverity.over
      : (projected > budget * 0.9 ? BudgetSeverity.tight : BudgetSeverity.safe);

  return BudgetPreview(
    scope: scope,
    severity: severity,
    budget: budget,
    currentSpent: currentSpent,
    projected: projected,
    remaining: remaining,
    pct: pct,
  );
}