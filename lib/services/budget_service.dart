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