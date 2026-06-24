// P3.1.A — Pure date helpers. Mirrors patterns already present inline:
// DateUtils.getDaysInMonth, DateUtils.dateOnly, and the "last day of month"
// idiom DateTime(y, m + 1, 0).day used by nextOccurrence / billingWindow.
// Nothing changes about how dates are computed — these are the canonical
// wrappers later extractions (subscription_rules.dart) will adopt.
//
// Class is named ZDate, NOT DateUtils — Flutter's framework already exports
// a DateUtils from material/date.dart. Collision would silently shadow
// framework calls. ZDate is unambiguous.
import 'package:flutter/material.dart' show DateUtils;

class ZDate {
  ZDate._();

  // Days in the calendar month containing [d]. Forwards verbatim.
  static int daysInMonth(DateTime d) => DateUtils.getDaysInMonth(d.year, d.month);

  // Explicit (year, month) variant — matches call sites that already pass
  // tuples (e.g. last-month computations in _StatsTab).
  static int daysInMonthOf(int year, int month) => DateUtils.getDaysInMonth(year, month);

  // Midnight projection. Wraps DateUtils.dateOnly to contain the import.
  static DateTime dateOnly(DateTime d) => DateUtils.dateOnly(d);

  // First instant of the calendar month containing [d].
  static DateTime monthStart(DateTime d) => DateTime(d.year, d.month, 1);

  // Last day-of-month for arbitrary (year, month). Uses the standard
  // "day 0 of next month" idiom present inline in nextOccurrence and
  // billingWindow. Handles month=13 → next year naturally via DateTime.
  static int lastDayOf(int year, int month) => DateTime(year, month + 1, 0).day;

  // True iff [a] and [b] fall in the same calendar month.
  static bool sameMonth(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month;
}