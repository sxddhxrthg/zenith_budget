// P3.1.D — Pure insight string builders extracted verbatim from main.dart.
// No behavior changes. These functions:
//   • depend only on already-loaded data passed in by callers
//   • have no BuildContext, no State, no setState, no SharedPreferences, no DB writes
//   • only assemble human-readable summary strings
//
// `cats` is typed Iterable<dynamic> for the same reason subscription_service.dart
// keeps it dynamic: the category model class is internal and not worth coupling
// here. Member access (.id, .name, .icon) resolves at runtime identically to
// the original inline call sites, which carried no explicit type either.
//
// Wording, ordering, conditions, joins, and emoji are all byte-for-byte
// identical to the originals. Do not "improve" them here; this is a refactor.
import 'dart:math' as math;
import 'package:flutter/material.dart' show DateUtils;
import 'package:intl/intl.dart' hide TextDirection;
import '../models/transaction.dart';
import '../utils/formatters.dart';

// Home tab insight string (originally _Home._ins). Single-line summary
// shown above the activity list. Returns the empty-state copy when the
// month has no expense activity yet.
String homeInsight({
  required List<Txn> txns,
  required Iterable<dynamic> cats,
  required double tExp,
  required int monthBud,
}) {
  final now = DateTime.now(); final dp = now.day; final dl = DateUtils.getDaysInMonth(now.year, now.month) - dp;
  final da = dp > 0 && tExp > 0 ? tExp / dp : 0.0;
  final top = cats.map((c) => MapEntry(c, txns.where((t) => t.type == 'expense' && t.date.year == now.year && t.date.month == now.month && t.category == c.id).fold(0.0, (s, t) => s + t.amount))).where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
  if (top.isEmpty) return 'No spending this month yet. Your insights will appear as you spend.';
  final p = <String>[];
  if (monthBud > 0) { final proj = da * DateUtils.getDaysInMonth(now.year, now.month); p.add(proj > monthBud * 1.1 ? 'At this pace: ${fmtAmt(proj)} — ${((proj / monthBud - 1) * 100).round()}% over budget.' : 'On track — ${fmtAmt(monthBud - tExp)} left, $dl days.'); }
  p.add('Top: ${top.first.key.icon} ${top.first.key.name} ${fmtAmt(top.first.value)}.');
  if (da > 0) p.add('Avg: ${fmtAmt(da)}/day.');
  return p.join(' ');
}

// Stats tab AI overview string (originally _StatsTab._ai). Multi-line
// summary shown in the AI Overview card. Builds expense count, projection,
// savings rate, biggest charge, peak weekday, and week-over-week delta.
String statsInsight({
  required List<Txn> txns,
  required double tExp,
  required double tInc,
  required int monthBud,
}) {
  final now = DateTime.now(); final dim = DateUtils.getDaysInMonth(now.year, now.month);
  final dp = now.day; final dl = dim - dp;
  final da = dp > 0 && tExp > 0 ? tExp / dp : 0.0; final proj = da * dim;
  if (tExp == 0) return 'No expenses this month yet. Add transactions to see spending insights.';
  final ec = txns.where((t) => t.type == 'expense' && t.date.year == now.year && t.date.month == now.month).length;
  final mExp = txns.where((t) => t.type == 'expense' && t.date.month == now.month && t.date.year == now.year).toList();
  final p = <String>[];
  if (ec > 0) p.add('$ec expense${ec == 1 ? '' : 's'} this month, avg ${fmtAmt(tExp / ec)} each.');
  if (monthBud > 0) p.add(proj > monthBud ? '⚠️ Projected ${fmtAmt(proj)} exceeds ${fmtInt(monthBud)} budget.' : '✅ On track: ${fmtAmt(proj)} projected of ${fmtInt(monthBud)}.');
  if (tInc > 0) p.add('Savings: ${((tInc - tExp) / tInc * 100).round()}%.');
  if (dl > 0 && monthBud > 0 && monthBud > tExp) p.add('${fmtAmt((monthBud - tExp) / dl)}/day for remaining $dl days.');
  if (mExp.isNotEmpty) {
    final big = mExp.reduce((a, b) => a.amount > b.amount ? a : b);
    p.add('💸 Biggest this month: ${fmtAmt(big.amount)} on ${DateFormat('MMM d').format(big.date)}.');
    final w = List<double>.filled(7, 0); for (var t in mExp) w[t.date.weekday - 1] += t.amount;
    final mx = w.reduce(math.max);
    if (mx > 0) { final pk = w.indexOf(mx); const names = ['Mondays','Tuesdays','Wednesdays','Thursdays','Fridays','Saturdays','Sundays']; p.add('📅 You spend most on ${names[pk]}.'); }
  }
  final wkAgo = now.subtract(const Duration(days: 7)); final twoWkAgo = now.subtract(const Duration(days: 14));
  final tw = txns.where((t) => t.type == 'expense' && t.date.isAfter(wkAgo)).fold(0.0, (s, t) => s + t.amount);
  final pw = txns.where((t) => t.type == 'expense' && t.date.isAfter(twoWkAgo) && t.date.isBefore(wkAgo)).fold(0.0, (s, t) => s + t.amount);
  if (pw > 0) { final d = ((tw - pw) / pw * 100).round(); p.add('${d > 0 ? '📈' : '📉'} This week ${d > 0 ? 'up' : 'down'} ${d.abs()}% vs last week.'); }
  return p.join('\n');
}