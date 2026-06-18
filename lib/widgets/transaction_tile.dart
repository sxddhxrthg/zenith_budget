import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' hide TextDirection;
import '../models/transaction.dart';
import '../models/category.dart';
import '../utils/formatters.dart';

Widget buildTile(Txn t, ColorScheme cs, {VoidCallback? onTap}) {
  final c = fCat(t.category); final isI = t.type == 'income';
  return GestureDetector(onTap: onTap, child: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
    child: Row(children: [
      Container(width: 44, height: 44, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: (c?.color ?? const Color(0xFF64748B)).withOpacity(0.12)), child: Center(child: Text(c?.icon ?? '📌', style: const TextStyle(fontSize: 20)))),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.merchant, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 3),
        Text('${c?.name ?? "Other"} · ${fmtTxnTime(t.date)}', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4))),
        if (t.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(t.note, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.3), fontStyle: FontStyle.italic), maxLines: 1, overflow: TextOverflow.ellipsis))])),
      Text(isI ? '+${fmtAmt(t.amount)}' : '-${fmtAmt(t.amount)}', style: GoogleFonts.jetBrainsMono(fontSize: 15, fontWeight: FontWeight.w800, color: isI ? const Color(0xFF34D399) : const Color(0xFFEF4444)))])));
}

List<Widget> buildGrouped(List<Txn> txns, ColorScheme cs, ValueChanged<Txn> onTap, {int limit = 20, ValueChanged<Txn>? onDelete}) {
  final w = <Widget>[]; String? last;
  for (final t in txns.take(limit)) {
    final d = DateFormat('EEEE, d MMM').format(t.date);
    if (d != last) { last = d; final l = DateUtils.isSameDay(t.date, DateTime.now()) ? 'Today' : DateUtils.isSameDay(t.date, DateTime.now().subtract(const Duration(days: 1))) ? 'Yesterday' : d;
      w.add(Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 6), child: Text(l, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.45))))); }
    w.add(Dismissible(key: Key(t.id), background: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: const Color(0xFF3B82F6).withOpacity(0.15)),
        child: const Align(alignment: Alignment.centerLeft, child: Padding(padding: EdgeInsets.only(left: 20), child: Icon(Icons.edit_rounded, color: Color(0xFF3B82F6), size: 22)))),
      secondaryBackground: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: const Color(0xFFEF4444).withOpacity(0.15)),
        child: const Align(alignment: Alignment.centerRight, child: Padding(padding: EdgeInsets.only(right: 20), child: Icon(Icons.delete_rounded, color: Color(0xFFEF4444), size: 22)))),
      confirmDismiss: (dir) async { if (dir == DismissDirection.startToEnd) { HapticFeedback.lightImpact(); onTap(t); return false; } HapticFeedback.mediumImpact(); return true; },
      onDismissed: (_) => onDelete?.call(t),
      child: buildTile(t, cs, onTap: () => onTap(t)))); }
  return w;
}
