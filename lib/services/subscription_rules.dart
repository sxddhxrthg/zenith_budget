// P3.1.B — Pure subscription rule helpers extracted verbatim from main.dart.
// No behavior changes. These functions:
//   • depend only on the persisted subscription map shape, Txn, and Db.merchantKey
//   • have no BuildContext, no State, no setState, no SharedPreferences, no DB writes
//   • are read-only intelligence over already-loaded data
//
// Identity model is preserved: merchant + cadence + schedule. amount is
// deliberately NOT part of identity in subPaidAuto — price changes still count
// as paid for the cycle.
import 'package:intl/intl.dart' hide TextDirection;
import '../models/transaction.dart';
import '../services/db_service.dart';

// P3.1.E — monthly-equivalent spend for a subscription. Weekly subs are
// normalized to a monthly figure via 52 weeks / 12 months; monthly subs
// pass through unchanged. Pure: depends only on amount + cadence; identity
// fields (key, day, time) are irrelevant. Mirrors the duplicated inline
// helper previously defined twice in main.dart (Stats card + Insights card).
double monthlyEquivalent(Map<String, dynamic> sub) {
  final a = (sub['amount'] as num).toDouble();
  return sub['cadence'] == 'weekly' ? a * 52 / 12 : a;
}

// P2.7.6 — next billing occurrence for a subscription (weekly/monthly only).
// Pure: derived from stored cadence/day/time. Identity is merchant+schedule; amount
// is irrelevant here. Monthly clamps day to the month length (e.g. day 31 in Feb).
DateTime nextOccurrence(Map<String, dynamic> sub, DateTime now) {
  final parts = ((sub['time'] as String?) ?? '09:00').split(':');
  final hh = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 9;
  final mm = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
  final day = (sub['day'] as num?)?.toInt() ?? 1;
  if (sub['cadence'] == 'weekly') {
    final target = day.clamp(1, 7);
    final delta = (target - now.weekday) % 7; // Dart % is non-negative for positive divisor
    var cand = DateTime(now.year, now.month, now.day, hh, mm).add(Duration(days: delta));
    if (!cand.isAfter(now)) cand = cand.add(const Duration(days: 7));
    return cand;
  }
  DateTime onMonth(int y, int m) {
    final dim = DateTime(y, m + 1, 0).day; // last day of month m
    return DateTime(y, m, day.clamp(1, dim), hh, mm);
  }
  var cand = onMonth(now.year, now.month);
  if (!cand.isAfter(now)) cand = onMonth(now.month == 12 ? now.year + 1 : now.year, now.month == 12 ? 1 : now.month + 1);
  return cand;
}

// P2.7.7 — billing window [start, next) of the cycle that currently contains `now`.
// next is the upcoming charge; start is the previous occurrence (one cadence earlier,
// month-length clamped). Used to decide if THIS cycle has been paid.
({DateTime start, DateTime next}) billingWindow(Map<String, dynamic> sub, DateTime now) {
  final next = nextOccurrence(sub, now);
  if (sub['cadence'] == 'weekly') return (start: next.subtract(const Duration(days: 7)), next: next);
  final parts = ((sub['time'] as String?) ?? '09:00').split(':');
  final hh = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 9;
  final mm = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
  final day = (sub['day'] as num?)?.toInt() ?? 1;
  final py = next.month == 1 ? next.year - 1 : next.year;
  final pm = next.month == 1 ? 12 : next.month - 1;
  final dim = DateTime(py, pm + 1, 0).day;
  return (start: DateTime(py, pm, day.clamp(1, dim), hh, mm), next: next);
}

// Stable per-cycle key for the manual override map.
String paidId(Map<String, dynamic> sub, DateTime now) => '${sub['key']}@${DateFormat('yyyyMMdd').format(billingWindow(sub, now).start)}';

// Automatic detection: paid if ANY matching-merchant expense falls in the current cycle.
// Identity is merchant only — amount is deliberately ignored (price changes still count).
bool subPaidAuto(Map<String, dynamic> sub, List<Txn> txns, DateTime now) {
  final w = billingWindow(sub, now);
  final key = sub['key'] as String? ?? '';
  return txns.any((t) => t.type == 'expense' && Db.merchantKey(t.merchant) == key && !t.date.isBefore(w.start) && t.date.isBefore(w.next));
}

// Resolved status: manual override wins if present for this cycle, else automatic. Reusable by P2.7.8.
bool subPaidResolved(Map<String, dynamic> sub, List<Txn> txns, Map<String, bool> override, DateTime now) {
  final id = paidId(sub, now);
  if (override.containsKey(id)) return override[id]!;
  return subPaidAuto(sub, txns, now);
}