import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:firebase_core/firebase_core.dart';
import 'auth_bypass.dart';
import 'models/transaction.dart';
import 'models/category.dart';
import 'utils/formatters.dart';
import 'theme/app_constants.dart';
import 'widgets/painters.dart';
import 'widgets/transaction_tile.dart';
import 'widgets/budget_card.dart';
import 'widgets/empty_state.dart';
import 'widgets/floating_nav.dart';
import 'widgets/insight_card.dart';
import 'services/db_service.dart';
import 'services/settings_service.dart';
import 'services/notification_service.dart';
import 'utils/prefs_keys.dart';
import 'services/subscription_rules.dart';
import 'services/subscription_service.dart';
import 'services/budget_service.dart';
import 'services/insights_service.dart';


void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await Firebase.initializeApp(); } catch (_) {}
  await TimePref.load();
  runApp(const ZenithApp());
}

// ═══════════════════════════════════════
// DATABASE — amounts stored as-is, no rounding tricks
// Total monthly budget in SharedPreferences (single int, never split)
// Category budgets in SQLite ONLY if user explicitly sets them
// ═══════════════════════════════════════




// ═══ NATIVE BRIDGE ═══



// ═══ MODELS ═══



// ═══ APP ═══

class ZenithApp extends StatefulWidget { const ZenithApp({super.key}); @override State<ZenithApp> createState() => _ZenithAppState(); }
class _ZenithAppState extends State<ZenithApp> {
  ThemeMode _mode = ThemeMode.dark; Color _accent = const Color(0xFF00D4FF); int _scaleIdx = 2;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { final p = await SharedPreferences.getInstance(); setState(() { _mode = p.getString(PrefsKeys.theme) == 'light' ? ThemeMode.light : ThemeMode.dark; _accent = accents[(p.getInt(PrefsKeys.accent) ?? 0).clamp(0, 7)]; _scaleIdx = (p.getInt(PrefsKeys.fontScale) ?? 2).clamp(0, 4); }); }
  void _tTheme() async { final p = await SharedPreferences.getInstance(); setState(() { _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark; p.setString(PrefsKeys.theme, _mode == ThemeMode.light ? 'light' : 'dark'); }); }
  void _sAccent(int i) async { final p = await SharedPreferences.getInstance(); setState(() { _accent = accents[i.clamp(0, 7)]; p.setInt(PrefsKeys.accent, i); }); }
  void _sScale(int i) async { final p = await SharedPreferences.getInstance(); setState(() { _scaleIdx = i.clamp(0, 4); p.setInt(PrefsKeys.fontScale, _scaleIdx); }); }

  @override Widget build(BuildContext context) {
    final scale = scales[_scaleIdx];
    return MaterialApp(title: 'Zenith', debugShowCheckedModeBanner: false, themeMode: _mode,
      builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)), child: child!),
      theme: ThemeData(brightness: Brightness.light, colorSchemeSeed: _accent, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF5F5F7), textTheme: GoogleFonts.outfitTextTheme(ThemeData.light().textTheme)),
      darkTheme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: _accent, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFF0A0A14), textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme)),
      home: SimpleAuthGate(accent: _accent, onAuthenticated: (n) => Shell(accent: _accent, tTheme: _tTheme, sAccent: _sAccent, sScale: _sScale, scaleIdx: _scaleIdx, isDark: _mode == ThemeMode.dark, name: n)));
  }
}

// ═══ SHELL ═══

class Shell extends StatefulWidget {
  final Color accent; final VoidCallback tTheme; final ValueChanged<int> sAccent, sScale; final int scaleIdx; final bool isDark; final String name;
  const Shell({super.key, required this.accent, required this.tTheme, required this.sAccent, required this.sScale, required this.scaleIdx, required this.isDark, required this.name});
  @override State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int _tab = 0;
  List<Txn> _txns = [];
  Map<String, int> _catB = {};
  int _monthBud = 0;
  // P2.7.3 — approved subscriptions (persisted as JSON) + session-only "Not now".
  // A subscription = {key, name, amount, cadence, source}. Detection stays
  // separate: a merchant is "recurring" automatically but "subscribed" only
  // once the user approves it (or adds one manually).
  List<Map<String, dynamic>> _subs = [];
  final Set<String> _dismissedSubs = {};
  // P2.7.5 — entry-time subscription suggestion bookkeeping.
  // _declinedSubs: keys the user pressed "Not now" on (persisted, never re-asked).
  // _offeredSubs: keys already offered this session (passive ignore won't re-nag).
  Set<String> _declinedSubs = {};
  final Set<String> _offeredSubs = {};
  // P2.7.7 — manual paid/unpaid overrides, keyed "<subKey>@<cycleStartYYYYMMDD>".
  // Absent key = use automatic detection. Scoped per cycle, so it self-resets next cycle.
  Map<String, bool> _paidOverride = {};
  StreamSubscription? _sub;
  bool _notifOk = false, _loading = true, _asked = false;

  @override void initState() { super.initState(); _load(); _listen(); _checkNotif();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent, systemNavigationBarDividerColor: Colors.transparent)); }

  Future<void> _load() async {
    final rows = await Db.allTxns();
    final cb = await Db.catBudgets();
    final mb = await getMonthlyBudget();
    final pr = await SharedPreferences.getInstance();
    final raw = pr.getString(PrefsKeys.subscriptions);
    final subs = <Map<String, dynamic>>[];
    if (raw != null && raw.isNotEmpty) {
      try { for (final e in (jsonDecode(raw) as List)) subs.add(Map<String, dynamic>.from(e as Map)); } catch (_) {}
    }
    final parsed = rows.map((m) => Txn.fromMap(m)).toList();
    // P2.7.4.2 — backfill legacy subs that predate schedule fields. Use REAL
    // transaction history (day-of-month/weekday + actual charge time) instead of
    // letting schedOf fall back to the invented "Day 1 · 09:00". Never guess when
    // real info exists; records with no matching history are left for the user to edit.
    var subsChanged = false;
    for (final s in subs) {
      if (s['day'] != null && s['time'] != null) continue;
      final k = (s['key'] as String?) ?? '';
      final hist = parsed.where((t) => t.type == 'expense' && Db.merchantKey(t.merchant) == k).toList()..sort((a, b) => a.date.compareTo(b.date));
      if (hist.isEmpty) continue;
      final last = hist.last.date;
      s['day'] ??= (s['cadence'] == 'weekly') ? last.weekday : last.day;
      s['time'] ??= '${last.hour.toString().padLeft(2, '0')}:${last.minute.toString().padLeft(2, '0')}';
      subsChanged = true;
    }
    if (subsChanged) await pr.setString(PrefsKeys.subscriptions, jsonEncode(subs));
    final declined = (pr.getStringList(PrefsKeys.declinedSubMerchants) ?? const []).toSet();
    final po = <String, bool>{};
    final rawPaid = pr.getString(PrefsKeys.subPaidOverride);
    if (rawPaid != null && rawPaid.isNotEmpty) { try { (jsonDecode(rawPaid) as Map).forEach((k, v) { if (v is bool) po[k as String] = v; }); } catch (_) {} }
    if (mounted) setState(() { _txns = parsed; _catB = cb; _monthBud = mb; _subs = subs; _declinedSubs = declined; _paidOverride = po; _loading = false; });
  }

  Future<void> _persistSubs() async {
    final pr = await SharedPreferences.getInstance();
    await pr.setString(PrefsKeys.subscriptions, jsonEncode(_subs));
  }

  // Approve a subscription — from a detection suggestion OR manual entry. Keyed
  // by merchant key; duplicates ignored. The `recurring` set is never touched:
  // detected ≠ subscribed.
  Future<void> _approveSub(Map<String, dynamic> sub) async {
    HapticFeedback.lightImpact();
    final key = (sub['key'] as String?) ?? '';
    if (key.isEmpty || _subs.any((s) => s['key'] == key)) return;
    _subs = [..._subs, sub];
    await _persistSubs();
    // P2.7.9 — teach autocat: future charges from this merchant will pre-select
    // the Subscriptions category. Existing learning still wins on user override.
    final scid = _subsCatId();
    final mname = (sub['name'] as String?) ?? '';
    if (scid.isNotEmpty && mname.isNotEmpty) await Db.setAutoCat(mname, scid);
    await _load();
  }

  // Remove — manual control. Detection is unaffected, so the merchant may
  // resurface as a suggestion later.
  Future<void> _removeSub(String key) async {
    HapticFeedback.lightImpact();
    _subs = _subs.where((s) => s['key'] != key).toList();
    await _persistSubs();
    await _load();
  }

  // P2.7.4 — upsert by key: edit replaces in place, add appends. Used by the
  // add/edit sheet. Detection (`recurring`) is never touched.
  Future<void> _upsertSub(Map<String, dynamic> sub) async {
    HapticFeedback.lightImpact();
    final key = sub['key'] as String;
    final i = _subs.indexWhere((s) => s['key'] == key);
    _subs = (i >= 0) ? ([..._subs]..[i] = sub) : [..._subs, sub];
    await _persistSubs();
    // P2.7.9 — keep autocat in sync (idempotent; rename-safe on edit).
    final scid = _subsCatId();
    final mname = (sub['name'] as String?) ?? '';
    if (scid.isNotEmpty && mname.isNotEmpty) await Db.setAutoCat(mname, scid);
    await _load();
  }

  // P2.7.4 — unified Add / Edit subscription sheet. Weekly + Monthly only, with
  // an editable billing schedule (weekday or day-of-month) and time (def 09:00).
  // Controllers are intentionally not disposed in the async gap (see P2.7.3).
  Future<void> _subSheet({Map<String, dynamic>? existing}) async {
    HapticFeedback.lightImpact();
    final nameC = TextEditingController(text: existing?['name'] as String? ?? '');
    final amtC = TextEditingController(text: existing != null ? (existing['amount'] as num).toString() : '');
    String cadence = (existing?['cadence'] as String?) ?? 'monthly';
    int day = (existing?['day'] as num?)?.toInt() ?? (cadence == 'weekly' ? DateTime.now().weekday : DateTime.now().day);
    String time = (existing?['time'] as String?) ?? '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}';
    const wk = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final saved = await showModalBottomSheet<bool>(context: context, isScrollControlled: true, backgroundColor: Colors.transparent, builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return StatefulBuilder(builder: (ctx, setSt) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: cs.onSurface.withOpacity(0.15)))),
            const SizedBox(height: 16),
            Text(existing == null ? 'Add subscription' : 'Edit subscription', style: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w700, color: cs.onSurface)),
            const SizedBox(height: 16),
            TextField(controller: nameC, style: TextStyle(color: cs.onSurface), decoration: InputDecoration(labelText: 'Name', hintText: 'e.g. Netflix', filled: true, fillColor: cs.onSurface.withOpacity(0.06), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
            const SizedBox(height: 12),
            TextField(controller: amtC, keyboardType: const TextInputType.numberWithOptions(decimal: true), style: TextStyle(color: cs.onSurface), decoration: InputDecoration(labelText: 'Amount', prefixText: '₹ ', filled: true, fillColor: cs.onSurface.withOpacity(0.06), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
            const SizedBox(height: 12),
            Row(children: ['weekly', 'monthly'].map((c) { final sel = cadence == c; return Expanded(child: Padding(padding: const EdgeInsets.only(right: 8), child: GestureDetector(onTap: () { HapticFeedback.selectionClick(); setSt(() { cadence = c; day = c == 'weekly' ? DateTime.now().weekday : DateTime.now().day; }); }, child: Container(padding: const EdgeInsets.symmetric(vertical: 11), alignment: Alignment.center, decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: sel ? widget.accent.withOpacity(0.15) : cs.onSurface.withOpacity(0.04), border: Border.all(color: sel ? widget.accent : Colors.transparent)), child: Text('${c[0].toUpperCase()}${c.substring(1)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: sel ? widget.accent : cs.onSurface.withOpacity(0.6))))))); }).toList()),
            const SizedBox(height: 16),
            Text(cadence == 'weekly' ? 'Billing day' : 'Billing date', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.5))),
            const SizedBox(height: 8),
            if (cadence == 'weekly')
              Wrap(spacing: 6, runSpacing: 6, children: List.generate(7, (i) { final d = i + 1; final sel = day == d; return GestureDetector(onTap: () { HapticFeedback.selectionClick(); setSt(() => day = d); }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), decoration: BoxDecoration(borderRadius: BorderRadius.circular(9), color: sel ? widget.accent.withOpacity(0.15) : cs.onSurface.withOpacity(0.04), border: Border.all(color: sel ? widget.accent : Colors.transparent)), child: Text(wk[i], style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sel ? widget.accent : cs.onSurface.withOpacity(0.6))))); }))
            else
              Wrap(spacing: 6, runSpacing: 6, children: List.generate(31, (i) { final d = i + 1; final sel = day == d; return GestureDetector(onTap: () { HapticFeedback.selectionClick(); setSt(() => day = d); }, child: Container(width: 34, height: 34, alignment: Alignment.center, decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: sel ? widget.accent.withOpacity(0.15) : cs.onSurface.withOpacity(0.04), border: Border.all(color: sel ? widget.accent : Colors.transparent)), child: Text('$d', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: sel ? widget.accent : cs.onSurface.withOpacity(0.6))))); })),
            const SizedBox(height: 14),
            GestureDetector(behavior: HitTestBehavior.opaque, onTap: () async { final parts = time.split(':'); final picked = await showTimePicker(context: ctx, initialTime: TimeOfDay(hour: int.tryParse(parts.first) ?? 9, minute: int.tryParse(parts.length > 1 ? parts[1] : '0') ?? 0), builder: (c, w) => Theme(data: Theme.of(c).copyWith(colorScheme: Theme.of(c).colorScheme.copyWith(primary: widget.accent)), child: w!)); if (picked != null) setSt(() => time = '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}'); }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13), decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cs.onSurface.withOpacity(0.06)), child: Row(children: [Icon(Icons.schedule_rounded, size: 16, color: widget.accent), const SizedBox(width: 10), Text('Billing time', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.6))), const Spacer(), Text(time, style: GoogleFonts.jetBrainsMono(fontSize: 14, fontWeight: FontWeight.w700, color: cs.onSurface))]))),
            const SizedBox(height: 18),
            SizedBox(width: double.infinity, child: ElevatedButton(onPressed: () => Navigator.pop(ctx, true), style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, elevation: 0, padding: const EdgeInsets.symmetric(vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: Text(existing == null ? 'Save' : 'Update', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)))),
          ])),
        ),
      ));
    });
    if (saved == true) {
      final name = nameC.text.trim();
      final amt = double.tryParse(amtC.text.replaceAll(',', '').replaceAll('₹', '').trim()) ?? 0;
      if (name.isNotEmpty && amt > 0) {
        // P2.7 final — when editing an existing sub, the previous _upsertSub
        // call replaced the map outright and silently dropped previousAmount /
        // priceChangedAt. That's why "manual ₹500 → ₹560" updated the amount
        // but never surfaced an insight. Two cases now:
        //   • amount meaningfully changed → record this as a price change
        //     (same ≥1 AND ≥1% threshold as _maybeUpdateSubPrice, so manual
        //     and auto paths produce equivalent records);
        //   • amount unchanged → preserve any existing price-change history.
        final next = <String, dynamic>{
          'key': existing?['key'] as String? ?? Db.merchantKey(name),
          'name': Db.merchantDisplay(name),
          'amount': amt,
          'cadence': cadence,
          'day': day,
          'time': time,
          'source': existing?['source'] ?? 'manual',
        };
        if (existing != null) {
          final prevAmt = (existing['amount'] as num).toDouble();
          final d = (amt - prevAmt).abs();
          if (prevAmt > 0 && d >= 1 && d / prevAmt >= 0.01) {
            next['previousAmount'] = prevAmt;
            next['priceChangedAt'] = DateTime.now().toIso8601String();
          } else {
            if (existing['previousAmount'] != null) next['previousAmount'] = existing['previousAmount'];
            if (existing['priceChangedAt'] != null) next['priceChangedAt'] = existing['priceChangedAt'];
          }
        }
        await _upsertSub(next);
      }
    }
  }

  // Session-only dismiss — no persistence, recurrence detection unaffected.
  void _dismissSub(String key) { HapticFeedback.lightImpact(); setState(() => _dismissedSubs.add(key)); }

  // P2.7.5 — persist a "Not now" so this merchant is never suggested again at entry time.
  Future<void> _declineSub(String key) async {
    HapticFeedback.lightImpact();
    _declinedSubs = {..._declinedSubs, key};
    final pr = await SharedPreferences.getInstance();
    await pr.setStringList(PrefsKeys.declinedSubMerchants, _declinedSubs.toList());
  }

  // P2.7.7 — flip the paid state for this sub's CURRENT billing cycle. We only store an
  // override when it differs from automatic detection (keeps the map tiny + self-healing).
  Future<void> _toggleSubPaid(Map<String, dynamic> sub) async {
    HapticFeedback.selectionClick();
    final now = DateTime.now();
    final id = paidId(sub, now);
    final auto = subPaidAuto(sub, _txns, now);
    final current = _paidOverride.containsKey(id) ? _paidOverride[id]! : auto;
    final next = !current;
    setState(() { if (next == auto) { _paidOverride.remove(id); } else { _paidOverride[id] = next; } });
    final pr = await SharedPreferences.getInstance();
    await pr.setString(PrefsKeys.subPaidOverride, jsonEncode(_paidOverride));
  }

  // P3.1.C — moved to services/subscription_service.dart (subsCatId). Thin
  // forwarder preserves call sites; resolves against the live `cats` field.
  String _subsCatId() => subsCatId(cats);

  // P2.7.9 — price intelligence. After an expense lands, if it matches an
  // approved subscription and the amount diverges meaningfully from the stored
  // price, update the sub in place and remember the previous price so the
  // Insights card can surface "₹199 → ₹249". Identity = merchant + cadence +
  // schedule; amount is NEVER part of identity — we update, never duplicate.
  Future<void> _maybeUpdateSubPrice(Txn t) async {
    if (t.type != 'expense') return;
    final key = Db.merchantKey(t.merchant);
    if (key.isEmpty) return;
    final i = _subs.indexWhere((s) => s['key'] == key);
    if (i < 0) return;
    final sub = _subs[i];
    // P2.7 hardening — price updates may ONLY come from a transaction inside the
    // current billing window. This guards two cases:
    //   1. Editing/back-dating an old transaction (would otherwise rewrite price).
    //   2. Forward-dated entries — also out of window.
    // A sub with missing schedule has no trustworthy window, so we skip it; the
    // user can set the schedule and the next real charge will move the price.
    if (sub['day'] == null || sub['time'] == null) return;
    final now = DateTime.now();
    final w = billingWindow(sub, now);
    if (t.date.isBefore(w.start) || !t.date.isBefore(w.next)) return;
    final stored = (sub['amount'] as num).toDouble();
    if (stored <= 0) return;
    final diff = (t.amount - stored).abs();
    if (diff < 1 || diff / stored < 0.01) return;
    _subs = [..._subs]..[i] = {...sub, 'amount': t.amount, 'previousAmount': stored, 'priceChangedAt': t.date.toIso8601String()};
    await _persistSubs();
    if (mounted) setState(() {});
  }

  // P3.1.C — moved to services/subscription_service.dart (entryConfident).
  // Thin forwarder preserves call sites; passes live _txns into the pure helper.
  bool _entryConfident(Txn t, String key) => entryConfident(t, key, _txns);

  // P2.7.5 — entry-time subscription suggestion. Fires after an expense is logged;
  // non-blocking (the txn is already saved), one at a time, never auto-decides cadence.
  Future<void> _maybeSuggestSub(Txn t) async {
    if (t.type != 'expense') return;
    final key = Db.merchantKey(t.merchant);
    if (key.isEmpty) return;
    if (_subs.any((s) => s['key'] == key)) return;   // already a subscription
    if (_declinedSubs.contains(key)) return;          // user said Not now before
    if (_offeredSubs.contains(key)) return;           // already offered this session
    // P2.7.5.1 — confidence gate: don't interrupt for ordinary spending. A skip here
    // does NOT mark the merchant offered, so it can still ask once confidence rises.
    // P2.7.9 — picking the Subscriptions category at entry IS the confident signal;
    // bypass the heuristic gate entirely. Treats user intent as authoritative.
    final scid = _subsCatId();
    final categoryIsSubs = scid.isNotEmpty && t.category == scid;
    if (!categoryIsSubs && !_entryConfident(t, key)) return;
    _offeredSubs.add(key);
    // Let the Add sheet finish its exit animation before presenting this one.
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;
    String? cadence; // never preselected — automation assists, it does not decide.
    final result = await showModalBottomSheet<String>(context: context, isScrollControlled: true, backgroundColor: Colors.transparent, builder: (ctx) {
      final cs = Theme.of(ctx).colorScheme;
      return StatefulBuilder(builder: (ctx, setSt) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Container(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
          decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(22))),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Center(child: Container(width: 38, height: 4, decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: cs.onSurface.withOpacity(0.15)))),
            const SizedBox(height: 16),
            Row(children: [Icon(Icons.autorenew_rounded, size: 16, color: widget.accent), const SizedBox(width: 8), Text('Recurring expense detected', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: widget.accent))]),
            const SizedBox(height: 10),
            Text('${Db.merchantDisplay(t.merchant)}  ${fmtAmt(t.amount)}', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: cs.onSurface)),
            const SizedBox(height: 2),
            Text('Add this to subscriptions?', style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.5))),
            const SizedBox(height: 14),
            Row(children: ['weekly', 'monthly'].map((c) { final sel = cadence == c; return Expanded(child: Padding(padding: const EdgeInsets.only(right: 8), child: GestureDetector(onTap: () { HapticFeedback.selectionClick(); setSt(() => cadence = c); }, child: Container(padding: const EdgeInsets.symmetric(vertical: 11), alignment: Alignment.center, decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: sel ? widget.accent.withOpacity(0.15) : cs.onSurface.withOpacity(0.04), border: Border.all(color: sel ? widget.accent : Colors.transparent)), child: Text('${c[0].toUpperCase()}${c.substring(1)}', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: sel ? widget.accent : cs.onSurface.withOpacity(0.6))))))); }).toList()),
            const SizedBox(height: 18),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              OutlinedButton(onPressed: () => Navigator.pop(ctx, 'decline'), style: OutlinedButton.styleFrom(foregroundColor: cs.onSurface.withOpacity(0.7), side: BorderSide(color: cs.onSurface.withOpacity(0.22)), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), child: const Text('Not now', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: cadence == null ? null : () => Navigator.pop(ctx, cadence), style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, elevation: 0, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)), disabledBackgroundColor: widget.accent.withOpacity(0.3)), child: const Text('Add', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
            ]),
          ]),
        ),
      ));
    });
    if (result == 'decline') {
      await _declineSub(key);
    } else if (result == 'weekly' || result == 'monthly') {
      await _upsertSub({'key': key, 'name': Db.merchantDisplay(t.merchant), 'amount': t.amount, 'cadence': result, 'day': result == 'weekly' ? t.date.weekday : t.date.day, 'time': '${t.date.hour.toString().padLeft(2, '0')}:${t.date.minute.toString().padLeft(2, '0')}', 'source': 'auto'});
    }
    // null (tapped outside / back) = passive ignore: stays in _offeredSubs for this session only.
  }

  void _listen() {
    _sub = NB.stream.listen((data) async {
      final amt = (data['amount'] as num?)?.toDouble() ?? 0;
      final merch = data['merchant'] as String? ?? 'Unknown';
      final type = data['type'] as String? ?? 'debit';
      final src = data['source'] as String? ?? 'unknown';
      final acc = src == 'gpay' ? 'gpay' : 'bank';
      if (type == 'credit') { if (mounted) _showIncCat(amt, merch, acc); }
      else {
        final auto = await Db.getAutoCat(merch);
        if (auto != null) {
          final autoTxn = Txn(id: _uid(), amount: amt, merchant: merch, category: auto, account: acc, type: 'expense', date: DateTime.now());
          await Db.insTxn(autoTxn.toMap()); await _load();
          await _maybeUpdateSubPrice(autoTxn); // P2.7.9
          if (mounted) _snack('Auto: ${fmtAmt(amt)} → ${fCat(auto)?.name}', bg: const Color(0xFF22C55E));
        } else if (mounted) { _showExpCat(amt, merch, acc); }
      }
    });
  }

  String _uid() => DateTime.now().millisecondsSinceEpoch.toString();

  Future<void> _checkNotif() async {
    _notifOk = await NB.notifOk(); if (mounted) setState(() {});
    if (!_notifOk && !_asked) { _asked = true; Future.delayed(const Duration(seconds: 1), () { if (mounted && !_notifOk) _notifDlg(); }); }
  }

  void _notifDlg() => showDialog(context: context, builder: (ctx) => AlertDialog(
    title: const Text('Enable Auto-Detection', style: TextStyle(fontWeight: FontWeight.w800)),
    content: const Text('Zenith needs notification access to detect GPay and bank transactions.\n\nOnly payment amounts and merchant names are read.'),
    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Later')),
      ElevatedButton(onPressed: () { Navigator.pop(ctx); NB.openNotif(); Future.delayed(const Duration(seconds: 3), _checkNotif); },
        style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white), child: const Text('Enable'))]));

  void _showExpCat(double amt, String merch, String acc) => showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
    builder: (ctx) => _CatSheet(amount: amt, merchant: merch, accent: widget.accent, onSelect: (catId, note, auto) async {
      final t = Txn(id: _uid(), amount: amt, merchant: merch, category: catId, account: acc, type: 'expense', date: DateTime.now(), note: note);
      await Db.insTxn(t.toMap());
      if (auto) await Db.setAutoCat(merch, catId); await _load();
      await _maybeUpdateSubPrice(t); // P2.7.9
      await _maybeSuggestSub(t);     // P2.7.9 — Category → Subscription bridge
      if (ctx.mounted) Navigator.pop(ctx); }));

  void _showIncCat(double amt, String merch, String acc) => showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
    builder: (ctx) => _IncCatSheet(amount: amt, merchant: merch, accent: widget.accent, onSelect: (catId, note) async {
      await Db.insTxn(Txn(id: _uid(), amount: amt, merchant: merch, category: catId, account: acc, type: 'income', date: DateTime.now(), note: note).toMap());
      await _load(); if (ctx.mounted) Navigator.pop(ctx); }));

  void _showAdd() => showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
    builder: (ctx) => _AddSheet(accent: widget.accent, onAdd: (t) async {
      await Db.insTxn(t.toMap());
      if (t.type == 'expense' && t.merchant.trim().isNotEmpty && t.category.isNotEmpty) await Db.learnMerchant(t.merchant, t.category);
      await _load(); if (ctx.mounted) Navigator.pop(ctx);
      await _maybeUpdateSubPrice(t); // P2.7.9
      _maybeSuggestSub(t); }));

  void _showEdit(Txn t) => showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
    builder: (ctx) => _EditSheet(txn: t, accent: widget.accent,
      onSave: (u) async {
        await Db.updTxn(u.toMap());
        if (u.type == 'expense' && u.merchant.trim().isNotEmpty && u.category.isNotEmpty) await Db.learnMerchant(u.merchant, u.category);
        await _load(); if (ctx.mounted) Navigator.pop(ctx);
        await _maybeUpdateSubPrice(u); // P2.7.9
        _snack('Changes saved', bg: const Color(0xFF22C55E)); },
      onDelete: () async { final saved = t.toMap(); await Db.delTxn(t.id); await _load(); if (ctx.mounted) Navigator.pop(ctx);
        _snack('Transaction deleted', bg: const Color(0xFFEF4444), action: SnackBarAction(label: 'UNDO', textColor: Colors.white, onPressed: () async { HapticFeedback.lightImpact(); await Db.insTxn(saved); await _load(); }), seconds: 4); },
      onStopAuto: () async { await Db.stopAuto(t.merchant); await _load(); if (ctx.mounted) Navigator.pop(ctx);
        _snack('Stopped learning ${t.merchant}'); },
      onStartAuto: () async {
        if (t.category.isEmpty) { _snack('Pick a category first', bg: const Color(0xFFEF4444)); return; }
        await Db.setAutoCat(t.merchant, t.category); await _load(); if (ctx.mounted) Navigator.pop(ctx);
        _snack('Learning ${t.merchant} again', bg: const Color(0xFF22C55E)); }));

  void _delTxn(Txn t) async {
    HapticFeedback.mediumImpact(); final saved = t.toMap();
    await Db.delTxn(t.id); await _load();
    if (!mounted) return;
    _snack('Transaction deleted', bg: const Color(0xFFEF4444), action: SnackBarAction(label: 'UNDO', textColor: Colors.white, onPressed: () async { HapticFeedback.lightImpact(); await Db.insTxn(saved); await _load(); }), seconds: 4);
  }

  // High-contrast snackbar: default uses inverseSurface (always readable across
  // every accent + theme); colored variants (green success, red destructive)
  // use solid fills with white text for clarity.
  void _snack(String msg, {Color? bg, SnackBarAction? action, int seconds = 3}) {
    if (!mounted) return; ScaffoldMessenger.of(context).clearSnackBars();
    final cs = Theme.of(context).colorScheme;
    final fg = bg != null ? Colors.white : cs.onInverseSurface;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: fg)),
      backgroundColor: bg ?? cs.inverseSurface,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 88),
      duration: Duration(seconds: seconds),
      elevation: 6,
      action: action));
  }

  void _editMonthBud() { final c = TextEditingController(text: _monthBud > 0 ? '$_monthBud' : '');
    showDialog(context: context, builder: (ctx) { final cs = Theme.of(ctx).colorScheme; return AlertDialog(
      title: const Text('Monthly Budget', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: c, keyboardType: TextInputType.number, autofocus: true, style: GoogleFonts.jetBrainsMono(fontSize: 24, fontWeight: FontWeight.w700),
          decoration: InputDecoration(prefixText: '₹ ', hintText: '10000', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 8),
        Text('Enter exact amount. No rounding.', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4)))]),
      actions: [if (_monthBud > 0) TextButton(onPressed: () async { HapticFeedback.mediumImpact(); await setMonthlyBudget(0); await _load(); if (ctx.mounted) Navigator.pop(ctx); }, child: const Text('Remove', style: TextStyle(color: Color(0xFFEF4444)))),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () async { HapticFeedback.lightImpact(); final v = int.tryParse(c.text.replaceAll(',','').replaceAll(' ','')) ?? 0; await setMonthlyBudget(v); await _load(); if (ctx.mounted) Navigator.pop(ctx); },
          style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white), child: const Text('Save'))]); }); }

  void _editCatBud(String catId) { final cur = _catB[catId] ?? 0;
    final c = TextEditingController(text: cur > 0 ? '$cur' : '');
    showDialog(context: context, builder: (ctx) { final cs = Theme.of(ctx).colorScheme; return AlertDialog(
      title: Text('${fCat(catId)?.icon} ${fCat(catId)?.name ?? catId}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
      content: TextField(controller: c, keyboardType: TextInputType.number, autofocus: true, style: GoogleFonts.jetBrainsMono(fontSize: 24, fontWeight: FontWeight.w700),
        decoration: InputDecoration(prefixText: '₹ ', hintText: '0', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
      actions: [if (cur > 0) TextButton(onPressed: () async { HapticFeedback.mediumImpact(); await Db.delCatBudget(catId); await _load(); if (ctx.mounted) Navigator.pop(ctx); }, child: const Text('Remove', style: TextStyle(color: Color(0xFFEF4444)))),
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        ElevatedButton(onPressed: () async { HapticFeedback.lightImpact(); final v = int.tryParse(c.text.replaceAll(',','').replaceAll(' ','')) ?? 0; if (v > 0) await Db.setCatBudget(catId, v); else await Db.delCatBudget(catId); await _load(); if (ctx.mounted) Navigator.pop(ctx); },
          style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white), child: const Text('Save'))]); }); }

  // ─── Month-scoped totals ───────────────────────────────────────────────
  // tExp / tInc are misnamed for historical reasons — they always
  // represent the CURRENT calendar month, not lifetime. Budgets,
  // balance, projections, and AI insights all assume month semantics.
  // Historical transactions remain visible in Activity but never
  // contribute to other months' analytics.
  double get tExp => monthlyTotal(_txns, 'expense', DateTime.now());
  double get tInc => monthlyTotal(_txns, 'income', DateTime.now());

  @override void dispose() { _sub?.cancel(); super.dispose(); }
  @override Widget build(BuildContext context) {
    if (_loading) return Scaffold(body: Center(child: CircularProgressIndicator(color: widget.accent)));
    final cs = Theme.of(context).colorScheme;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final tabs = [
      _Home(txns: _txns, catB: _catB, monthBud: _monthBud, accent: widget.accent, name: widget.name, tExp: tExp, tInc: tInc, notifOk: _notifOk, onNotif: () { NB.openNotif(); Future.delayed(const Duration(seconds: 3), _checkNotif); }, onAdd: _showAdd, onTap: _showEdit, onEditBud: _editMonthBud, onDelete: _delTxn),
      _Activity(txns: _txns, onTap: _showEdit, onDelete: _delTxn),
      _BudgetsTab(txns: _txns, catB: _catB, monthBud: _monthBud, accent: widget.accent, onEditTotal: _editMonthBud, onEditCat: _editCatBud),
      _StatsTab(txns: _txns, accent: widget.accent, tExp: tExp, tInc: tInc, catB: _catB, monthBud: _monthBud, subs: _subs, approvedKeys: _subs.map((s) => s['key'] as String).toSet(), dismissedSubs: _dismissedSubs, declinedSubs: _declinedSubs, onApproveSub: _approveSub, onDismissSub: _dismissSub, onAddManual: () => _subSheet(), onEditSub: (s) => _subSheet(existing: s), onRemoveSub: _removeSub, paidOverride: _paidOverride, onTogglePaid: _toggleSubPaid),
      _Settings(accent: widget.accent, isDark: widget.isDark, notifOk: _notifOk, scaleIdx: widget.scaleIdx, tTheme: widget.tTheme, sAccent: widget.sAccent, sScale: widget.sScale, onNotif: () { NB.openNotif(); Future.delayed(const Duration(seconds: 3), _checkNotif); }),
    ];
    return Scaffold(body: Stack(children: [
      tabs[_tab],
      Positioned(right: 20, bottom: bottomPad + 76, child: GestureDetector(onTap: () { HapticFeedback.lightImpact(); _showAdd(); },
        child: Container(width: 52, height: 52, decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: widget.accent, boxShadow: [BoxShadow(color: widget.accent.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))]),
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 24)))),
      Positioned(left: 20, right: 20, bottom: bottomPad + 12, child: FloatingNav(currentIndex: _tab, accent: widget.accent, onSelect: (i) => setState(() => _tab = i)))]));
  }
}

// ═══ PAINTERS ═══



// ═══ HELPERS ═══



// ═══ HOME ═══

class _Home extends StatelessWidget {
  final List<Txn> txns; final Map<String, int> catB; final int monthBud; final Color accent; final String name; final bool notifOk;
  final double tExp, tInc; final VoidCallback onNotif, onAdd, onEditBud; final ValueChanged<Txn> onTap, onDelete;
  const _Home({required this.txns, required this.catB, required this.monthBud, required this.accent, required this.name, required this.notifOk, required this.tExp, required this.tInc, required this.onNotif, required this.onAdd, required this.onTap, required this.onEditBud, required this.onDelete});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final bal = tInc - tExp;

    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 0), child: Text('Hi, $name 👋', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface))),
      if (!notifOk) GestureDetector(onTap: onNotif, child: Container(margin: const EdgeInsets.fromLTRB(16, 10, 16, 0), padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: const Color(0xFFF43F5E).withOpacity(0.08)),
        child: Row(children: [const Icon(Icons.notifications_active_rounded, color: Color(0xFFF43F5E), size: 18), const SizedBox(width: 8), Expanded(child: Text('Enable GPay auto-detection', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurface)))]))),
      BudgetHeroCard(accent: accent, monthBud: monthBud, tExp: tExp, onTap: onEditBud),
      Container(margin: const EdgeInsets.fromLTRB(16, 8, 16, 0), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cs.surface),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Balance', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))), Text(fmtAmt(bal), style: GoogleFonts.jetBrainsMono(fontSize: 22, fontWeight: FontWeight.w800, color: bal >= 0 ? cs.onSurface : const Color(0xFFF43F5E)))]),
          Row(children: [_ms('In', '+${fmtAmt(tInc)}', const Color(0xFF22C55E), cs), const SizedBox(width: 14), _ms('Out', '-${fmtAmt(tExp)}', const Color(0xFFF43F5E), cs)])])),
      if (txns.isNotEmpty) InsightCard(accent: accent, emoji: '💡', body: _ins()),
      ...buildGrouped(txns, cs, onTap, limit: 20, onDelete: onDelete),
if (txns.isEmpty) const EmptyState(
        icon: Icons.receipt_long_rounded,
        title: 'No transactions yet',
        subtitle: 'Your spending will appear here\nautomatically from GPay'),
    ]));
  }

  Widget _kv(String l, String v, Color c, ColorScheme cs) => Padding(padding: const EdgeInsets.only(bottom: 2), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))), Text(v, style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: c))]));
  Widget _ms(String l, String v, Color c, ColorScheme cs) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(l, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.35))), Text(v, style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: c))]);
  // P3.1.D — body extracted to services/insights_service.dart::homeInsight.
  String _ins() => homeInsight(txns: txns, cats: cats, tExp: tExp, monthBud: monthBud);
}

// ═══ ACTIVITY ═══

class _Activity extends StatefulWidget {
  final List<Txn> txns; final ValueChanged<Txn> onTap, onDelete;
  const _Activity({required this.txns, required this.onTap, required this.onDelete});
  @override State<_Activity> createState() => _ActivityState();
}

class _ActivityState extends State<_Activity> {
  final _qCtl = TextEditingController(); String _q = ''; String _type = 'all';
  final Set<String> _cats = {}; final Set<String> _accs = {}; DateTimeRange? _range;

  @override void dispose() { _qCtl.dispose(); super.dispose(); }

  List<Txn> get _filtered { final q = _q.trim().toLowerCase();
    return widget.txns.where((t) {
      if (_type != 'all' && t.type != _type) return false;
      if (_cats.isNotEmpty && !_cats.contains(t.category)) return false;
      if (_accs.isNotEmpty && !_accs.contains(t.account)) return false;
      if (_range != null) { final d = DateUtils.dateOnly(t.date); if (d.isBefore(DateUtils.dateOnly(_range!.start)) || d.isAfter(DateUtils.dateOnly(_range!.end))) return false; }
      if (q.isNotEmpty) { final cn = fCat(t.category)?.name.toLowerCase() ?? ''; if (!t.merchant.toLowerCase().contains(q) && !t.note.toLowerCase().contains(q) && !cn.contains(q)) return false; }
      return true; }).toList();
  }

  bool get _hasFilter => _q.isNotEmpty || _type != 'all' || _cats.isNotEmpty || _accs.isNotEmpty || _range != null;
  void _clear() { HapticFeedback.lightImpact(); setState(() { _qCtl.clear(); _q = ''; _type = 'all'; _cats.clear(); _accs.clear(); _range = null; }); }

  Future<void> _pickRange() async { final now = DateTime.now();
    final r = await showDateRangePicker(context: context, firstDate: DateTime(now.year - 5), lastDate: DateTime(now.year + 1), initialDateRange: _range);
    if (r != null) setState(() => _range = r);
  }

  void _pickType() { showModalBottomSheet(context: context, backgroundColor: Colors.transparent, builder: (ctx) { final cs = Theme.of(ctx).colorScheme; final ac = Theme.of(context).colorScheme.primary;
    return Container(decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))), padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: cs.onSurface.withOpacity(0.15), borderRadius: BorderRadius.circular(2))),
        const Text('Type', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        ...['all','expense','income'].map((t) => ListTile(contentPadding: EdgeInsets.zero, title: Text(t == 'all' ? 'All' : t == 'expense' ? 'Expense' : 'Income', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          trailing: _type == t ? Icon(Icons.check_rounded, color: ac) : null,
          onTap: () { HapticFeedback.selectionClick(); setState(() => _type = t); Navigator.pop(ctx); }))])); }); }

  void _pickMulti(String title, Set<String> sel, List<MapEntry<String, String>> opts) {
    showModalBottomSheet(context: context, backgroundColor: Colors.transparent, isScrollControlled: true, builder: (ctx) { final cs = Theme.of(ctx).colorScheme; final ac = Theme.of(context).colorScheme.primary;
      return StatefulBuilder(builder: (ctx, setSt) => Container(decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 32), constraints: BoxConstraints(maxHeight: MediaQuery.of(ctx).size.height * 0.7),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(width: 40, height: 4, margin: const EdgeInsets.only(bottom: 16), decoration: BoxDecoration(color: cs.onSurface.withOpacity(0.15), borderRadius: BorderRadius.circular(2))),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            if (sel.isNotEmpty) TextButton(onPressed: () { HapticFeedback.lightImpact(); setSt(() => sel.clear()); setState(() {}); }, child: const Text('Clear', style: TextStyle(fontWeight: FontWeight.w600)))]),
          const SizedBox(height: 8),
          Flexible(child: SingleChildScrollView(child: Wrap(spacing: 8, runSpacing: 8, children: opts.map((o) { final on = sel.contains(o.key);
            return GestureDetector(onTap: () { HapticFeedback.selectionClick(); setSt(() { on ? sel.remove(o.key) : sel.add(o.key); }); setState(() {}); },
              child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: on ? ac.withOpacity(0.15) : cs.outline.withOpacity(0.06), border: Border.all(color: on ? ac : Colors.transparent, width: 1)),
                child: Text(o.value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: on ? ac : cs.onSurface)))); }).toList())))]))); });
  }

  Widget _chip(ColorScheme cs, String label, bool active, IconData icon, VoidCallback onTap) { final ac = Theme.of(context).colorScheme.primary;
    return GestureDetector(onTap: () { HapticFeedback.lightImpact(); onTap(); }, child: Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: active ? ac.withOpacity(0.15) : cs.outline.withOpacity(0.06), border: Border.all(color: active ? ac.withOpacity(0.6) : Colors.transparent, width: 1)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(icon, size: 14, color: active ? ac : cs.onSurface.withOpacity(0.6)), const SizedBox(width: 6), Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: active ? ac : cs.onSurface.withOpacity(0.75)))])));
  }

  String _accLbl(String a) => a == 'gpay' ? 'GPay' : a == 'bank' ? 'Bank' : a == 'cash' ? 'Cash' : a[0].toUpperCase() + a.substring(1);

  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme;
    final filtered = _filtered;
    final cats = widget.txns.map((t) => t.category).toSet().toList();
    final accs = widget.txns.map((t) => t.account).toSet().toList();
    return SafeArea(child: Column(children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 4), child: Row(children: [
        Expanded(child: Text('Activity', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface))),
        if (_hasFilter) TextButton(onPressed: _clear, child: const Text('Clear', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)))])),
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 12), child: Text(_hasFilter ? '${filtered.length} of ${widget.txns.length} transaction${widget.txns.length == 1 ? '' : 's'}' : '${widget.txns.length} transaction${widget.txns.length == 1 ? '' : 's'}', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4)))),
      Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 10), child: Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.outline.withOpacity(0.06)),
        child: TextField(controller: _qCtl, onChanged: (v) => setState(() => _q = v), style: TextStyle(fontSize: 14, color: cs.onSurface),
          decoration: InputDecoration(hintText: 'Search merchant, note, category…', hintStyle: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.35)), prefixIcon: Icon(Icons.search_rounded, color: cs.onSurface.withOpacity(0.4), size: 20),
            suffixIcon: _q.isNotEmpty ? IconButton(icon: Icon(Icons.close_rounded, color: cs.onSurface.withOpacity(0.4), size: 18), onPressed: () { HapticFeedback.lightImpact(); _qCtl.clear(); setState(() => _q = ''); }) : null,
            border: InputBorder.none, contentPadding: const EdgeInsets.symmetric(vertical: 12))))),
      SizedBox(height: 36, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
        _chip(cs, _type == 'expense' ? 'Expense' : _type == 'income' ? 'Income' : 'Type', _type != 'all', Icons.swap_vert_rounded, _pickType),
        const SizedBox(width: 8),
        _chip(cs, _cats.isEmpty ? 'Category' : '${_cats.length} categor${_cats.length == 1 ? "y" : "ies"}', _cats.isNotEmpty, Icons.category_rounded, () => _pickMulti('Categories', _cats, cats.map((c) { final cc = fCat(c); return MapEntry(c, '${cc?.icon ?? "📌"}  ${cc?.name ?? c}'); }).toList())),
        const SizedBox(width: 8),
        _chip(cs, _accs.isEmpty ? 'Account' : '${_accs.length} account${_accs.length == 1 ? "" : "s"}', _accs.isNotEmpty, Icons.account_balance_wallet_rounded, () => _pickMulti('Accounts', _accs, accs.map((a) => MapEntry(a, _accLbl(a))).toList())),
        const SizedBox(width: 8),
        _chip(cs, _range == null ? 'Date' : '${DateFormat('d MMM').format(_range!.start)} – ${DateFormat('d MMM').format(_range!.end)}', _range != null, Icons.calendar_today_rounded, _pickRange)])),
      const SizedBox(height: 6),
      Expanded(child: filtered.isEmpty
        ? EmptyState(
            icon: _hasFilter ? Icons.search_off_rounded : Icons.swap_vert_rounded,
            title: _hasFilter ? 'No matches' : 'No activity yet',
            subtitle: _hasFilter ? 'Try a different search or clear filters' : 'Transactions will show up here\nas you spend')
        : ListView(padding: const EdgeInsets.only(bottom: 120), children: buildGrouped(filtered, cs, widget.onTap, limit: 500, onDelete: widget.onDelete)))]));
  }
}

// ═══ BUDGETS ═══

class _BudgetsTab extends StatefulWidget {
  final List<Txn> txns; final Map<String, int> catB; final int monthBud; final Color accent; final VoidCallback onEditTotal; final ValueChanged<String> onEditCat;
  const _BudgetsTab({required this.txns, required this.catB, required this.monthBud, required this.accent, required this.onEditTotal, required this.onEditCat});
  @override State<_BudgetsTab> createState() => _BudgetsTabState();
}
class _BudgetsTabState extends State<_BudgetsTab> {
  bool _showAll = false;
  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme; final n = DateTime.now();
    final txns = widget.txns; final catB = widget.catB; final monthBud = widget.monthBud;
    final accent = widget.accent;
    final tExp = txns.where((t) => t.type == 'expense' && t.date.year == n.year && t.date.month == n.month).fold(0.0, (s, t) => s + t.amount);
    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 14), child: Text('Budgets', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface))),
      // ── Budget status card (only when budget is set) ──────────────────────
      if (monthBud > 0) BudgetStatusCard(monthBud: monthBud, tExp: tExp),
      GestureDetector(onTap: widget.onEditTotal, child: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: LinearGradient(colors: [accent.withOpacity(0.1), Colors.purple.withOpacity(0.05)])),
        child: Row(children: [const Text('💰', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
          Expanded(child: Text('Monthly Budget', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface))),
          Text(monthBud > 0 ? fmtInt(monthBud) : 'Not set', style: GoogleFonts.jetBrainsMono(fontSize: 16, fontWeight: FontWeight.w700, color: monthBud > 0 ? accent : cs.onSurface.withOpacity(0.3))),
          const SizedBox(width: 6), Icon(Icons.edit_rounded, size: 16, color: cs.onSurface.withOpacity(0.3))]))),
      const SizedBox(height: 8),
      // ── Section header + show-all toggle ──────────────────────────────────
      Padding(padding: const EdgeInsets.fromLTRB(18, 4, 16, 8), child: Row(children: [
        Expanded(child: Text('Category budgets (optional — tap to set)', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.35)))),
        GestureDetector(
          onTap: () { HapticFeedback.lightImpact(); setState(() => _showAll = !_showAll); },
          child: Text(_showAll ? 'Show less' : 'Show all', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: accent))),
      ])),
      // ── Category rows ──────────────────────────────────────────────────────
      ...cats.map((cat) {
        final bud = catB[cat.id] ?? 0;
        final spent = txns.where((t) => t.type == 'expense' && t.category == cat.id && t.date.year == n.year && t.date.month == n.month).fold(0.0, (s, t) => s + t.amount);
        // Filter: hide categories with no budget AND no spending this month,
        // unless the user tapped "Show all".
        if (!_showAll && bud == 0 && spent == 0) return const SizedBox.shrink();
        final pct = bud > 0 ? (spent / bud).clamp(0.0, 1.0) : 0.0;
        // Urgency tier
        final isOver    = bud > 0 && spent > bud;
        final isWarning = bud > 0 && !isOver && pct >= 0.8;
        final urgColor  = isOver ? const Color(0xFFF43F5E) : isWarning ? const Color(0xFFF59E0B) : const Color(0xFF22C55E);
        final rightLabel = bud > 0
            ? (isOver ? 'Over!' : '${fmtAmt(bud - spent)} left')
            : null;
        final rightColor = isOver ? const Color(0xFFF43F5E) : isWarning ? const Color(0xFFF59E0B) : const Color(0xFF22C55E);
        return GestureDetector(onTap: () => widget.onEditCat(cat.id), child: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3), padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
          child: Column(children: [Row(children: [Text(cat.icon, style: const TextStyle(fontSize: 20)), const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(cat.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
              Text(bud > 0 ? '${fmtAmt(spent)} / ${fmtInt(bud)}' : spent > 0 ? fmtAmt(spent) : 'No budget set', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4)))])),
            rightLabel != null
                ? Text(rightLabel, style: GoogleFonts.jetBrainsMono(fontSize: 11, fontWeight: FontWeight.w700, color: rightColor))
                : Icon(Icons.add_rounded, size: 18, color: cs.onSurface.withOpacity(0.2))]),
          if (bud > 0) ...[const SizedBox(height: 8),
            ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: pct, minHeight: 5, backgroundColor: cs.outline.withOpacity(0.1), valueColor: AlwaysStoppedAnimation(urgColor)))],
          // Spending-only row (no budget set) — show a dim bar as context
          if (bud == 0 && spent > 0) ...[const SizedBox(height: 6),
            Text('${fmtAmt(spent)} spent this month — tap to set a budget', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.35)))],
        ])));
      }).toList()]));
  }
}

// ═══ STATS ═══

// P3.1.B — nextOccurrence / billingWindow / paidId / subPaidAuto /
// subPaidResolved moved to services/subscription_rules.dart. Pure helpers;
// behavior unchanged.

class _StatsTab extends StatelessWidget {
  final List<Txn> txns; final Color accent; final double tExp, tInc; final Map<String, int> catB; final int monthBud;
  final List<Map<String, dynamic>> subs; final Set<String> approvedKeys; final Set<String> dismissedSubs; final Set<String> declinedSubs;
  final Future<void> Function(Map<String, dynamic>) onApproveSub; final void Function(String) onDismissSub; final Future<void> Function() onAddManual; final void Function(Map<String, dynamic>) onEditSub; final Future<void> Function(String) onRemoveSub;
  final Map<String, bool> paidOverride; final Future<void> Function(Map<String, dynamic>) onTogglePaid;
  const _StatsTab({required this.txns, required this.accent, required this.tExp, required this.tInc, required this.catB, required this.monthBud, required this.subs, required this.approvedKeys, required this.dismissedSubs, required this.declinedSubs, required this.onApproveSub, required this.onDismissSub, required this.onAddManual, required this.onEditSub, required this.onRemoveSub, required this.paidOverride, required this.onTogglePaid});
  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme;
    final now = DateTime.now(); final dim = DateUtils.getDaysInMonth(now.year, now.month);
    final dp = now.day; final dl = dim - dp;
    final da = dp > 0 && tExp > 0 ? tExp / dp : 0.0;
    final proj = da * dim;
    final pie = cats.map((c) => MapEntry(c, txns.where((t) => t.type == 'expense' && t.category == c.id && t.date.year == now.year && t.date.month == now.month).fold(0.0, (s, t) => s + t.amount))).where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final dayAmt = <int, double>{};
    for (var t in txns.where((t) => t.type == 'expense' && t.date.month == now.month && t.date.year == now.year)) dayAmt[t.date.day] = (dayAmt[t.date.day] ?? 0) + t.amount;
    final maxDay = dayAmt.values.isEmpty ? 1.0 : dayAmt.values.reduce(math.max);
    final daily = List<double>.filled(dp, 0);
    for (var t in txns.where((t) => t.type == 'expense' && t.date.month == now.month && t.date.year == now.year)) if (t.date.day <= dp) daily[t.date.day - 1] += t.amount;
    final cum = <double>[]; double cumR = 0; for (var d in daily) { cumR += d; cum.add(cumR); }
    final lmDate = DateTime(now.year, now.month - 1, 1);
    final tmExp = txns.where((t) => t.type == 'expense' && t.date.year == now.year && t.date.month == now.month).fold(0.0, (s, t) => s + t.amount);
    final lmExp = txns.where((t) => t.type == 'expense' && t.date.year == lmDate.year && t.date.month == lmDate.month).fold(0.0, (s, t) => s + t.amount);
    final mom = lmExp > 0 ? ((tmExp - lmExp) / lmExp * 100) : 0.0;
    final wd = List<double>.filled(7, 0);
    for (var t in txns.where((t) => t.type == 'expense' && t.date.month == now.month && t.date.year == now.year)) wd[t.date.weekday - 1] += t.amount;
    final maxWd = wd.fold(0.0, math.max);
    // Top merchants this month — case-insensitive grouping, canonical display.
    final mm = <String, double>{};
    final mDisp = <String, String>{};
    for (var t in txns.where((t) => t.type == 'expense' && t.date.year == now.year && t.date.month == now.month)) { final k = Db.merchantKey(t.merchant); if (k.isEmpty) continue; mm[k] = (mm[k] ?? 0) + t.amount; mDisp[k] ??= Db.merchantDisplay(t.merchant); }
    final top5 = (mm.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).take(5).toList();
    // Recurring detection scans ALL expenses (lifetime) — the pattern itself
    // is "this merchant recurs". It does not leak into month-scoped totals.
    final byM = <String, List<Txn>>{};
    for (var t in txns.where((t) => t.type == 'expense')) { final k = Db.merchantKey(t.merchant); if (k.isEmpty) continue; (byM[k] ??= []).add(t); }
    // P2.7.3 — store the representative charge (median) + cadence directly. No
    // monthly-normalization math: users think in "₹X / month", not formulas.
    final recurring = <String>{};
    final recurMeta = <String, ({double amount, bool weekly, int day, String disp})>{};
    byM.forEach((m, list) { if (list.length < 3) return; final s = [...list]..sort((a, b) => a.date.compareTo(b.date)); final amts = s.map((t) => t.amount).toList(); final avg = amts.reduce((a, b) => a + b) / amts.length; if (avg <= 0) return; if (!amts.every((a) => (a - avg).abs() / avg <= 0.2)) return; final gaps = <int>[]; for (var i = 1; i < s.length; i++) gaps.add(s[i].date.difference(s[i-1].date).inDays); final ag = gaps.reduce((a, b) => a + b) / gaps.length; if (!gaps.every((g) => (g - ag).abs() <= 4)) return; final weekly = ag >= 6 && ag <= 8; final monthly = ag >= 25 && ag <= 35; if (weekly || monthly) { recurring.add(m); final sa = [...amts]..sort(); recurMeta[m] = (amount: sa[sa.length ~/ 2], weekly: weekly, day: weekly ? s.last.date.weekday : s.last.date.day, disp: Db.merchantDisplay(s.last.merchant)); } });

    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 14), child: Text('Analytics', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface))),
      Container(margin: const EdgeInsets.fromLTRB(16, 0, 16, 0), padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Projected this month', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
              Text('Your daily average × days in month', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.3)))]),
            Text(fmtAmt(proj), style: GoogleFonts.jetBrainsMono(fontSize: 22, fontWeight: FontWeight.w800, color: monthBud > 0 && proj > monthBud ? const Color(0xFFF43F5E) : cs.onSurface))]),
          if (monthBud > 0) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Budget: ${fmtInt(monthBud)}', style: TextStyle(fontSize: 11, color: accent, fontWeight: FontWeight.w600))),
          if (dl > 0 && monthBud > 0 && monthBud > tExp) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Daily budget left: ${fmtAmt((monthBud - tExp) / dl)}', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.5))))])),
      Container(margin: const EdgeInsets.fromLTRB(16, 10, 16, 0), padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${DateFormat('MMMM').format(now)} spending', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
          const SizedBox(height: 8),
          if (maxWd > 0) Padding(padding: const EdgeInsets.only(bottom: 12), child: Row(children: List.generate(7, (i) { final v = wd[i]; final h = (v / maxWd) * 26; final lbl = ['M','T','W','T','F','S','S'][i]; final isPeak = v == maxWd && v > 0;
            return Expanded(child: Column(children: [
              SizedBox(height: 26, child: Align(alignment: Alignment.bottomCenter, child: Container(height: h.clamp(2, 26), margin: const EdgeInsets.symmetric(horizontal: 3), decoration: BoxDecoration(borderRadius: BorderRadius.circular(2), color: accent.withOpacity(isPeak ? 0.85 : 0.25))))),
              const SizedBox(height: 5),
              Text(lbl, style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: isPeak ? accent : cs.onSurface.withOpacity(0.3)))]));
          }))),
          Wrap(spacing: 4, runSpacing: 4, children: List.generate(dim, (i) {
            final day = i + 1; final amt = dayAmt[day] ?? 0; final isToday = day == dp; final isFuture = day > dp;
            final intensity = amt > 0 ? 0.15 + (amt / maxDay) * 0.85 : 0.0;
            return Container(width: 22, height: 22, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4),
              color: isFuture ? cs.outline.withOpacity(0.03) : amt > 0 ? accent.withOpacity(intensity) : cs.outline.withOpacity(0.06),
              border: isToday ? Border.all(color: accent, width: 1.5) : null),
              child: Center(child: Text('$day', style: TextStyle(fontSize: 8, fontWeight: FontWeight.w600, color: amt > 0 && !isFuture ? (intensity > 0.5 ? Colors.white : cs.onSurface) : cs.onSurface.withOpacity(isFuture ? 0.15 : 0.3)))));
          }))])),
      if (cum.length > 1) Container(margin: const EdgeInsets.fromLTRB(16, 10, 16, 0), padding: const EdgeInsets.fromLTRB(14, 14, 14, 20), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Spending trend', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
            Text(fmtAmt(cumR), style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: const Color(0xFFF43F5E)))]),
          Text('Day 1 → Day $dp', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.3))),
          const SizedBox(height: 10),
          SizedBox(height: 90, child: CustomPaint(size: const Size(double.infinity, 90), painter: TrendPainter(cum, accent)))])),
      if (lmExp > 0) Container(margin: const EdgeInsets.fromLTRB(16, 10, 16, 0), padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Monthly report', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
            Container(padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4), decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: (mom > 0 ? const Color(0xFFF43F5E) : const Color(0xFF10B981)).withOpacity(0.12)),
              child: Text('${mom > 0 ? '↑' : '↓'} ${mom.abs().toStringAsFixed(0)}%', style: GoogleFonts.jetBrainsMono(fontSize: 11, fontWeight: FontWeight.w700, color: mom > 0 ? const Color(0xFFF43F5E) : const Color(0xFF10B981))))]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('This month', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))), const SizedBox(height: 3), Text(fmtAmt(tmExp), style: GoogleFonts.jetBrainsMono(fontSize: 17, fontWeight: FontWeight.w800, color: cs.onSurface))])),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(DateFormat('MMMM').format(lmDate), style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))), const SizedBox(height: 3), Text(fmtAmt(lmExp), style: GoogleFonts.jetBrainsMono(fontSize: 17, fontWeight: FontWeight.w800, color: cs.onSurface.withOpacity(0.5)))]))]),
          if (tmExp > 0 && lmExp > 0) Padding(padding: const EdgeInsets.only(top: 10), child: Text(mom > 0 ? 'You spent ${fmtAmt(tmExp - lmExp)} more than ${DateFormat('MMMM').format(lmDate)}.' : 'You saved ${fmtAmt(lmExp - tmExp)} compared to ${DateFormat('MMMM').format(lmDate)}.', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.5))))])),
      if (pie.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 8), child: Text('BREAKDOWN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.35), letterSpacing: 1))),
        Center(child: SizedBox(width: 160, height: 160, child: CustomPaint(painter: PiePainter(pie, tExp, Theme.of(context).scaffoldBackgroundColor)))),
        const SizedBox(height: 12),
        ...pie.map((e) { final p = tExp > 0 ? (e.value / tExp * 100).round() : 0; final cb = catB[e.key.id] ?? 0;
          return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3), child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), color: e.key.color)),
            const SizedBox(width: 8), Text(e.key.icon), const SizedBox(width: 6),
            Expanded(child: Text(e.key.name, style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.6)))),
            cb > 0 ? Text('${fmtAmt(e.value)}/${fmtInt(cb)}', style: GoogleFonts.jetBrainsMono(fontSize: 10, color: e.value > cb ? const Color(0xFFF43F5E) : cs.onSurface.withOpacity(0.4)))
              : Text(fmtAmt(e.value), style: GoogleFonts.jetBrainsMono(fontSize: 10, fontWeight: FontWeight.w700, color: e.key.color)),
            const SizedBox(width: 8), SizedBox(width: 32, child: Text('$p%', style: GoogleFonts.jetBrainsMono(fontSize: 10, color: cs.onSurface.withOpacity(0.35)), textAlign: TextAlign.right))])); })],
      if (top5.isNotEmpty) Container(margin: const EdgeInsets.fromLTRB(16, 14, 16, 0), padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Top merchants', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)), Text(DateFormat('MMMM').format(now), style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.3)))]),
          const SizedBox(height: 10),
          ...top5.map((e) { final isRec = recurring.contains(e.key) || approvedKeys.contains(e.key); return Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Row(children: [
            Expanded(child: Row(children: [
              Flexible(child: Text(mDisp[e.key] ?? e.key, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface), overflow: TextOverflow.ellipsis)),
              if (isRec) Padding(padding: const EdgeInsets.only(left: 8), child: Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: accent.withOpacity(0.12)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.autorenew_rounded, size: 10, color: accent), const SizedBox(width: 3), Text('Recurring', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: accent))])))])),
            Text(fmtAmt(e.value), style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: cs.onSurface))])); })])),
      // ── P2.6.1 Spending shifts (this month vs last month by category) ──────
      Builder(builder: (_) {
        // Per-category totals for this month and last month
        final catTm = <String, double>{};
        final catLm = <String, double>{};
        for (final t in txns.where((t) => t.type == 'expense')) {
          if (t.date.year == now.year && t.date.month == now.month) {
            catTm[t.category] = (catTm[t.category] ?? 0) + t.amount;
          } else if (t.date.year == lmDate.year && t.date.month == lmDate.month) {
            catLm[t.category] = (catLm[t.category] ?? 0) + t.amount;
          }
        }
        // Union of categories with spend in either month
        final allCats = {...catTm.keys, ...catLm.keys};
        // Build deltas; ignore zero-in-both and tiny changes (<₹100)
        final deltas = allCats.map((id) {
          final tm = catTm[id] ?? 0.0;
          final lm = catLm[id] ?? 0.0;
          return MapEntry(id, tm - lm);
        }).where((e) => e.value.abs() >= 100).toList()
          ..sort((a, b) => b.value.abs().compareTo(a.value.abs()));
        final shifts = deltas.take(5).toList();
        if (shifts.isEmpty) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Spending shifts', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
              Text('vs ${DateFormat('MMM').format(lmDate)}', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.3))),
            ]),
            const SizedBox(height: 10),
            ...shifts.map((e) {
              final cat = fCat(e.key);
              final isUp = e.value > 0;
              final color = isUp ? const Color(0xFFF43F5E) : const Color(0xFF22C55E);
              final arrow = isUp ? '↑' : '↓';
              final tm = catTm[e.key] ?? 0.0;
              final lm = catLm[e.key] ?? 0.0;
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  if (cat != null) Text(cat.icon, style: const TextStyle(fontSize: 16)),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(cat?.name ?? e.key, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)),
                    Text('${fmtAmt(lm)} → ${fmtAmt(tm)}', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.4))),
                  ])),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), color: color.withOpacity(0.10)),
                    child: Text('$arrow ${fmtAmt(e.value.abs())}', style: GoogleFonts.jetBrainsMono(fontSize: 11, fontWeight: FontWeight.w700, color: color)),
                  ),
                ]),
              );
            }),
          ]),
        );
      }),
      // ── P2.6.2 Spending concentration (top categories by share this month) ──
      Builder(builder: (_) {
        // Reuse `pie`: already month-scoped expenses per category, value > 0,
        // sorted descending by amount. Take the top 5.
        final top = pie.take(5).toList();
        if (top.isEmpty || tExp <= 0) return const SizedBox.shrink();
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Text('Where it goes', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
              Text(DateFormat('MMMM').format(now), style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.3))),
            ]),
            const SizedBox(height: 12),
            ...top.map((e) {
              final cat = e.key;
              final share = (e.value / tExp).clamp(0.0, 1.0);
              final pct = (share * 100).round();
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(cat.icon, style: const TextStyle(fontSize: 15)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(cat.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface), overflow: TextOverflow.ellipsis)),
                    Text('$pct%', style: GoogleFonts.jetBrainsMono(fontSize: 12, fontWeight: FontWeight.w700, color: cat.color)),
                    const SizedBox(width: 10),
                    SizedBox(width: 64, child: Text(fmtAmt(e.value), textAlign: TextAlign.right, style: GoogleFonts.jetBrainsMono(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.55)))),
                  ]),
                  const SizedBox(height: 6),
                  ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(
                    value: share,
                    minHeight: 5,
                    backgroundColor: cs.outline.withOpacity(0.08),
                    valueColor: AlwaysStoppedAnimation(cat.color),
                  )),
                ]),
              );
            }),
          ]),
        );
      }),
      // ── P2.6.3 Unusual spend (this month's outlier expenses) ───────────────
      Builder(builder: (_) {
        // This month's expenses, largest first.
        final monthExp = txns.where((t) =>
            t.type == 'expense' &&
            t.date.year == now.year &&
            t.date.month == now.month).toList()
          ..sort((a, b) => b.amount.compareTo(a.amount));
        // Need a stable baseline before anything counts as "unusual".
        if (monthExp.length < 4) return const SizedBox.shrink();
        // Median is robust to outliers (mean would be dragged up by the very
        // spikes we're hunting, masking them).
        final sorted = monthExp.map((t) => t.amount).toList()..sort();
        final n = sorted.length;
        final median = n.isOdd
            ? sorted[n ~/ 2]
            : (sorted[n ~/ 2 - 1] + sorted[n ~/ 2]) / 2;
        if (median <= 0) return const SizedBox.shrink();
        // Flag: ≥ 2.5× the typical spend AND ≥ ₹500 (ignore tiny expenses).
        // Recurring merchants (P2.4 detection) are expected, not unusual — a
        // ₹1800 monthly Gym charge is large but contextually normal, so we
        // exclude any merchant in the `recurring` set regardless of magnitude.
        final anomalies = monthExp
            .where((t) {
              final k = Db.merchantKey(t.merchant);
              // Recurring (auto-detected) AND approved subscriptions (user-managed)
              // are both expected spending — never flag them as unusual, even when
              // a sub hasn't accumulated enough detections to enter `recurring`.
              return t.amount >= median * 2.5 &&
                  t.amount >= 500 &&
                  !recurring.contains(k) &&
                  !approvedKeys.contains(k);
            })
            .take(5)
            .toList();
        if (anomalies.isEmpty) return const SizedBox.shrink();
        const warn = Color(0xFFF59E0B);
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: warn.withOpacity(0.06),
            border: Border.all(color: warn.withOpacity(0.18)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              const Icon(Icons.warning_amber_rounded, size: 16, color: warn),
              const SizedBox(width: 8),
              Text('Unusual spend', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ]),
            const SizedBox(height: 10),
            ...anomalies.map((t) {
              final cat = fCat(t.category);
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(children: [
                  if (cat != null) Text(cat.icon, style: const TextStyle(fontSize: 15)),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t.merchant.trim().isEmpty ? (cat?.name ?? 'Expense') : t.merchant, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface), overflow: TextOverflow.ellipsis),
                    Text(DateFormat('d MMM').format(t.date), style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.4))),
                  ])),
                  Text(fmtAmt(t.amount), style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: warn)),
                ]),
              );
            }),
          ]),
        );
      }),
      // ── P2.7.2 Recurring-payment suggestion (first unapproved merchant) ────
      Builder(builder: (_) {
        final pend = recurMeta.entries
            .where((e) => !approvedKeys.contains(e.key) && !dismissedSubs.contains(e.key) && !declinedSubs.contains(e.key))
            .toList()..sort((a, b) => b.value.amount.compareTo(a.value.amount));
        if (pend.isEmpty) return const SizedBox.shrink();
        final e = pend.first;
        // P2.7.4 — auto schedule: day comes from history (recurMeta); there is no
        // real billing *time* in txn history, so use the current time rather than a
        // hardcoded guess. Never invent schedule info when real info exists.
        final nowHM = '${DateTime.now().hour.toString().padLeft(2, '0')}:${DateTime.now().minute.toString().padLeft(2, '0')}';
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: accent.withOpacity(0.06), border: Border.all(color: accent.withOpacity(0.18))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.autorenew_rounded, size: 16, color: accent),
              const SizedBox(width: 8),
              Text('Recurring payment detected', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent)),
            ]),
            const SizedBox(height: 10),
            Text(e.value.disp, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface), overflow: TextOverflow.ellipsis),
            const SizedBox(height: 2),
            Text('${fmtAmt(e.value.amount)} / ${e.value.weekly ? 'week' : 'month'} · add to subscriptions?', style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.5))),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              OutlinedButton(onPressed: () => onDismissSub(e.key), style: OutlinedButton.styleFrom(foregroundColor: cs.onSurface.withOpacity(0.7), side: BorderSide(color: cs.onSurface.withOpacity(0.22)), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), child: const Text('Not now', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              const SizedBox(width: 4),
              ElevatedButton(onPressed: () => onApproveSub({'key': e.key, 'name': e.value.disp, 'amount': e.value.amount, 'cadence': e.value.weekly ? 'weekly' : 'monthly', 'day': e.value.day, 'time': nowHM, 'source': 'auto'}), style: ElevatedButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, elevation: 0, padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))), child: const Text('Add', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700))),
            ]),
          ]),
        );
      }),
      // ── P2.7.1/3 Subscriptions — ONLY user-approved subs (auto or manual) ──
      Builder(builder: (_) {
        final sorted = [...subs]..sort((a, b) => (b['amount'] as num).compareTo(a['amount'] as num));
        // Never invent schedule. Legacy/missing values surface as a tap target
        // ("Set schedule") that opens the existing edit sheet, where _subSheet's
        // own defaults handle the empty state — we don't silently fabricate.
        String schedOf(Map<String, dynamic> s) { final tRaw = s['time'] as String?; final dRaw = (s['day'] as num?)?.toInt(); if (tRaw == null || dRaw == null) return 'Set schedule'; if (s['cadence'] == 'weekly') { const w = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']; return '${w[(dRaw - 1).clamp(0, 6)]} · $tRaw'; } return 'Day $dRaw · $tRaw'; }
        final est = sorted.fold(0.0, (t, s) => t + monthlyEquivalent(s));
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              Row(children: [
                Icon(Icons.autorenew_rounded, size: 16, color: accent),
                const SizedBox(width: 8),
                Text('Subscriptions', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
              ]),
              if (sorted.isNotEmpty) Text('≈ ${fmtInt(est.round())}/mo', style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: accent)),
            ]),
            const SizedBox(height: 4),
            Text(sorted.isEmpty ? 'No subscriptions yet — approve a detected one or add manually.' : '${sorted.length} active ${sorted.length == 1 ? 'subscription' : 'subscriptions'}', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))),
            if (sorted.isNotEmpty) const SizedBox(height: 6),
            ...sorted.map((s) => Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: GestureDetector(
              onTap: () => onEditSub(s),
              onLongPress: () => onRemoveSub(s['key'] as String),
              behavior: HitTestBehavior.opaque,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Expanded(child: Row(children: [
                    Flexible(child: Text(s['name'] as String? ?? '', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface), overflow: TextOverflow.ellipsis)),
                    const SizedBox(width: 8),
                    Container(padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2), decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: accent.withOpacity(0.12)), child: Text('${(s['cadence'] as String)[0].toUpperCase()}${(s['cadence'] as String).substring(1)}', style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: accent))),
                  ])),
                  Text(fmtAmt((s['amount'] as num).toDouble()), style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: cs.onSurface)),
                ]),
                const SizedBox(height: 2),
                Row(children: [
                  Expanded(child: Text(schedOf(s), style: TextStyle(fontSize: 10.5, color: cs.onSurface.withOpacity(0.4)))),
                  Builder(builder: (_) { final paid = subPaidResolved(s, txns, paidOverride, DateTime.now()); return GestureDetector(onTap: () => onTogglePaid(s), behavior: HitTestBehavior.opaque, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3), decoration: BoxDecoration(borderRadius: BorderRadius.circular(6), color: paid ? const Color(0xFF22C55E).withOpacity(0.14) : cs.onSurface.withOpacity(0.05)), child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(paid ? Icons.check_circle_rounded : Icons.circle_outlined, size: 11, color: paid ? const Color(0xFF22C55E) : cs.onSurface.withOpacity(0.4)), const SizedBox(width: 4), Text(paid ? 'Paid' : 'Mark paid', style: TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700, color: paid ? const Color(0xFF22C55E) : cs.onSurface.withOpacity(0.45)))]))); }),
                ]),
              ]),
            ))),
            const SizedBox(height: 10),
            GestureDetector(onTap: onAddManual, behavior: HitTestBehavior.opaque, child: Container(
              padding: const EdgeInsets.symmetric(vertical: 11), alignment: Alignment.center,
              decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), border: Border.all(color: accent.withOpacity(0.4), width: 1.2)),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add_rounded, size: 16, color: accent),
                const SizedBox(width: 6),
                Text('Add subscription', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent)),
              ]),
            )),
            if (sorted.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Tap to edit · long-press to remove.', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.3)))),
          ]),
        );
      }),
      // ── P2.7.6 Upcoming Payments — next charge per subscription, nearest first ──
      // P2.7 final:
      //  • "Today" detected from stored day/weekday, NOT from nextOccurrence —
      //    so a sub still labels "Today" after its scheduled hh:mm has passed.
      //  • Card stays fully expanded; the Stats tab itself is a ListView.
      //  • Typography: Today → accent, Tomorrow → onSurface, future → muted.
      Builder(builder: (_) {
        if (subs.isEmpty) return const SizedBox.shrink();
        final now = DateTime.now();
        final today = DateUtils.dateOnly(now);
        bool isTodaySched(Map<String, dynamic> sub) {
          final day = (sub['day'] as num?)?.toInt();
          if (day == null) return false;
          if (sub['cadence'] == 'weekly') return day.clamp(1, 7) == now.weekday;
          final dim = DateUtils.getDaysInMonth(now.year, now.month);
          return day.clamp(1, dim) == now.day;
        }
        final items = subs.map((sub) => (s: sub, next: nextOccurrence(sub, now), today: isTodaySched(sub))).toList()
          ..sort((a, b) {
            // Today first, then chronological — so a charged-today sub doesn't
            // sink below subs that genuinely fire tomorrow.
            if (a.today != b.today) return a.today ? -1 : 1;
            return a.next.compareTo(b.next);
          });
        ({String text, Color color, FontWeight weight}) labelFor(({Map<String, dynamic> s, DateTime next, bool today}) it) {
          if (it.today) return (text: 'Today', color: accent, weight: FontWeight.w700);
          final days = DateUtils.dateOnly(it.next).difference(today).inDays;
          if (days == 1) return (text: 'Tomorrow', color: cs.onSurface.withOpacity(0.85), weight: FontWeight.w700);
          return (text: DateFormat('d MMM').format(it.next), color: cs.onSurface.withOpacity(0.55), weight: FontWeight.w600);
        }
        return Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.schedule_rounded, size: 16, color: accent),
              const SizedBox(width: 8),
              Text('Upcoming', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ]),
            const SizedBox(height: 4),
            Text('Next ${items.length == 1 ? 'payment' : 'payments'}', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))),
            const SizedBox(height: 6),
            ...items.map((it) {
              final lbl = labelFor(it);
              final paid = subPaidResolved(it.s, txns, paidOverride, now);
              return Padding(padding: const EdgeInsets.symmetric(vertical: 7), child: Row(children: [
                Expanded(child: Text(it.s['name'] as String? ?? '', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface), overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Text(fmtAmt((it.s['amount'] as num).toDouble()), style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: cs.onSurface)),
                const SizedBox(width: 12),
                if (paid) const Padding(padding: EdgeInsets.only(right: 5), child: Icon(Icons.check_circle_rounded, size: 12, color: Color(0xFF22C55E))),
                SizedBox(width: 72, child: Text(lbl.text, textAlign: TextAlign.right, style: TextStyle(fontSize: 11.5, fontWeight: lbl.weight, color: lbl.color))),
              ]));
            }),
          ]),
        );
      }),
      // ── P2.7.8 Subscription Insights — derived analytics over approved subs ──
      // Reuses nextOccurrence / billingWindow / subPaidResolved. Pure read-side;
      // never writes. Each alert row is conditional — empty states stay quiet.
      //
      // P2.7 stabilization:
      //  • fmtInt already prepends ₹ — never prefix a literal '₹' on top of it.
      //  • Inactive (60–89d) and cancel-candidate (90+d) are mutually exclusive.
      //  • Brand-new subs (no history at all) appear in neither.
      //  • "Overdue" → "Unpaid this cycle"; no arbitrary cycle-start buffer.
      //  • Price-change rows capped at 3, remainder aggregated.
      Builder(builder: (_) {
        if (subs.isEmpty) return const SizedBox.shrink();
        final now = DateTime.now();
        final monthlySpend = subs.fold(0.0, (t, s) => t + monthlyEquivalent(s));
        final largest = [...subs]..sort((a, b) => (b['amount'] as num).compareTo(a['amount'] as num));
        final weekly = subs.where((s) => s['cadence'] == 'weekly').toList();
        final monthly = subs.where((s) => s['cadence'] == 'monthly').toList();
        final weeklyAmt = weekly.fold(0.0, (t, s) => t + monthlyEquivalent(s));
        final monthlyAmt = monthly.fold(0.0, (t, s) => t + monthlyEquivalent(s));
        // Unpaid this cycle: no matching expense within the current billing
        // window. The previous 2-day buffer was arbitrary; the renamed wording
        // ("unpaid this cycle") makes the early-cycle case self-explanatory.
        final unpaid = subs.where((s) => !subPaidResolved(s, txns, paidOverride, now)).toList();
        final cutoff60 = now.subtract(const Duration(days: 60));
        final cutoff90 = now.subtract(const Duration(days: 90));
        DateTime? lastSeen(String key) {
          DateTime? last;
          for (final t in txns) { if (t.type != 'expense') continue; if (Db.merchantKey(t.merchant) != key) continue; if (last == null || t.date.isAfter(last)) last = t.date; }
          return last;
        }
        // Named record fields, and a non-nullable `last` — the null case is
        // already filtered out by `if (ls == null) continue;` below.
        final inactive = <({Map<String, dynamic> sub, DateTime last})>[];
        final cancelCandidates = <({Map<String, dynamic> sub, DateTime last})>[];
        for (final s in subs) {
          final ls = lastSeen((s['key'] as String?) ?? '');
          // No history at all → brand-new sub; not silent, not abandoned.
          if (ls == null) continue;
          // 90+ days takes precedence over 60–89; never both.
          if (ls.isBefore(cutoff90)) {
            cancelCandidates.add((sub: s, last: ls));
          } else if (ls.isBefore(cutoff60)) {
            inactive.add((sub: s, last: ls));
          }
        }
        // Price intelligence — derived purely from transaction history. The
        // most recent expense for the merchant is the "current" amount; we walk
        // backwards to find the most recent earlier amount that differs by both
        // ≥₹1 AND ≥1% (same tolerance as _maybeUpdateSubPrice, so surfaced
        // changes mirror the ones that triggered a stored-amount update).
        // No new storage; previousAmount/priceChangedAt on the sub are not
        // consulted — real charges are the source of truth, not stored deltas.
        final priceChanges = <({Map<String, dynamic> sub, double prev, double curr})>[];
        for (final s in subs) {
          final k = (s['key'] as String?) ?? '';
          if (k.isEmpty) continue;
          final hist = txns.where((t) => t.type == 'expense' && Db.merchantKey(t.merchant) == k).toList()
            ..sort((a, b) => a.date.compareTo(b.date));
          if (hist.length < 2) continue;
          final curr = hist.last.amount;
          double? prev;
          for (int i = hist.length - 2; i >= 0; i--) {
            final a = hist[i].amount;
            final d = (curr - a).abs();
            if (d >= 1 && d / curr >= 0.01) { prev = a; break; }
          }
          if (prev != null) priceChanges.add((sub: s, prev: prev, curr: curr));
        }

        Widget metric(String label, String value) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.45))),
          const SizedBox(height: 4),
          Text(value, style: GoogleFonts.jetBrainsMono(fontSize: 14, fontWeight: FontWeight.w700, color: cs.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis),
        ]));
        // Largest gets its own builder so long names ellipsize without truncating
        // the amount — name takes Expanded, amount stays fully visible.
        Widget largestMetric(String name, String amount) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Largest', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.45))),
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Flexible(child: Text(name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis)),
            const SizedBox(width: 6),
            Text(amount, style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: cs.onSurface)),
          ]),
        ]));
        // Cadence breakdown: count gets a large monospace number, the monthly
        // equivalent sits below as a caption. Reads cleaner than a single line.
        Widget cadenceMetric(String label, int count, double amt) => Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(label, style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.45))),
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text('$count', style: GoogleFonts.jetBrainsMono(fontSize: 16, fontWeight: FontWeight.w800, color: cs.onSurface)),
            const SizedBox(width: 5),
            Text(count == 1 ? 'sub' : 'subs', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.5))),
          ]),
          const SizedBox(height: 2),
          Text('≈ ${fmtInt(amt.round())}/mo', style: GoogleFonts.jetBrainsMono(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.55))),
        ]));
        Widget alertRow(IconData ic, Color c, String text) => Padding(padding: const EdgeInsets.only(top: 10), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(ic, size: 13, color: c), const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 11.5, color: cs.onSurface.withOpacity(0.75), height: 1.4))),
        ]));

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(Icons.insights_rounded, size: 16, color: accent),
              const SizedBox(width: 8),
              Text('Subscription Insights', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
            ]),
            const SizedBox(height: 14),
            Row(children: [
              metric('Monthly spend', fmtInt(monthlySpend.round())),
              largestMetric(largest.first['name'] as String? ?? '', fmtInt((largest.first['amount'] as num).round())),
            ]),
            const SizedBox(height: 14),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              cadenceMetric('Weekly', weekly.length, weeklyAmt),
              cadenceMetric('Monthly', monthly.length, monthlyAmt),
            ]),
            if (unpaid.isNotEmpty)
              alertRow(Icons.warning_amber_rounded, const Color(0xFFF59E0B),
                unpaid.length == 1
                  ? '${unpaid.first['name']} — unpaid this cycle'
                  : '${unpaid.length} subscriptions unpaid this cycle'),
            if (priceChanges.isNotEmpty) ...[
              // Low-density layout per spec: name on line one, amounts on line
              // two as "₹prev → ₹curr". Up/down arrow conveys direction without
              // adding verb text.
              Padding(padding: const EdgeInsets.only(top: 14, bottom: 2), child: Row(children: [
                Icon(Icons.trending_up_rounded, size: 13, color: accent),
                const SizedBox(width: 6),
                Text('PRICE CHANGES', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: accent, letterSpacing: 1)),
              ])),
              ...priceChanges.take(3).map((pc) {
                final up = pc.curr > pc.prev;
                return Padding(padding: const EdgeInsets.only(top: 8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded, size: 13, color: up ? const Color(0xFFF59E0B) : const Color(0xFF22C55E)),
                  const SizedBox(width: 8),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(pc.sub['name'] as String? ?? '', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis),
                    const SizedBox(height: 1),
                    Text('${fmtInt(pc.prev.round())} → ${fmtInt(pc.curr.round())}', style: GoogleFonts.jetBrainsMono(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.6))),
                  ])),
                ]));
              }),
              if (priceChanges.length > 3)
                Padding(padding: const EdgeInsets.only(top: 6, left: 21), child: Text('+${priceChanges.length - 3} more price changes', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.5)))),
            ],
            if (inactive.isNotEmpty)
              alertRow(Icons.nightlight_round, cs.onSurface.withOpacity(0.5),
                inactive.length == 1
                  ? '${inactive.first.sub['name']} — no charges in 60 days'
                  : '${inactive.length} inactive (no charges in 60d)'),
            if (cancelCandidates.isNotEmpty)
              alertRow(Icons.cancel_outlined, const Color(0xFFEF4444),
                cancelCandidates.length == 1
                  ? 'Consider cancelling ${cancelCandidates.first.sub['name']} — silent for 90+ days'
                  : '${cancelCandidates.length} candidates to cancel — silent for 90+ days'),
          ]),
        );
      }),
      if (txns.isNotEmpty) InsightCard(accent: accent, emoji: '🧠', title: 'AI Overview', body: _ai()),
    ]));
  }

  // P3.1.D — body extracted to services/insights_service.dart::statsInsight.
  String _ai() => statsInsight(txns: txns, tExp: tExp, tInc: tInc, monthBud: monthBud);
}

// ═══ SETTINGS ═══

class _Settings extends StatefulWidget {
  final Color accent; final bool isDark, notifOk; final int scaleIdx; final VoidCallback tTheme, onNotif; final ValueChanged<int> sAccent, sScale;
  const _Settings({required this.accent, required this.isDark, required this.notifOk, required this.scaleIdx, required this.tTheme, required this.sAccent, required this.sScale, required this.onNotif});
  @override State<_Settings> createState() => _SettingsState();
}
class _SettingsState extends State<_Settings> {
  bool _bio = false; String _name = '';
  @override void initState() { super.initState(); _lp(); }
  Future<void> _lp() async { final p = await SharedPreferences.getInstance(); setState(() { _bio = p.getBool(PrefsKeys.biometric) ?? false; _name = p.getString(PrefsKeys.userName) ?? ''; }); }
  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 14), child: Text('Settings', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface))),
      // ── PROFILE ──
      Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(18), decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: cs.surface),
        child: Row(children: [CircleAvatar(radius: 26, backgroundColor: widget.accent.withOpacity(0.15), child: Text(_name.isNotEmpty ? _name[0].toUpperCase() : '?', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: widget.accent))),
          const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(_name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: cs.onSurface)), Text('Local account', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4)))]))])),
      // ── SECURITY ──
      _sec('SECURITY', Icons.shield_rounded, cs),
      _tog('Fingerprint Lock', Icons.fingerprint_rounded, _bio, (v) async { HapticFeedback.lightImpact(); final p = await SharedPreferences.getInstance(); p.setBool(PrefsKeys.biometric, v); setState(() => _bio = v); }, cs),
      _row('Notification Access', Icons.notifications_rounded, widget.notifOk ? 'Enabled' : 'Disabled', widget.onNotif, cs, sc: widget.notifOk ? const Color(0xFF34D399) : const Color(0xFFEF4444)),
      // ── APPEARANCE ──
      _sec('APPEARANCE', Icons.palette_rounded, cs),
     _row('Theme', widget.isDark ? Icons.dark_mode_rounded : Icons.wb_sunny_rounded, widget.isDark ? 'Dark' : 'Light', widget.tTheme, cs),
      _tog('24-hour Time', Icons.schedule_rounded, TimePref.use24h, (v) async { HapticFeedback.lightImpact(); await TimePref.set(v); setState(() {}); }, cs),
      Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(16), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Accent Color', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)), const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: List.generate(8, (i) { final c = accents[i]; return GestureDetector(onTap: () { HapticFeedback.lightImpact(); widget.sAccent(i); }, child: Container(width: 36, height: 36, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.value == widget.accent.value ? cs.onSurface : Colors.transparent, width: 2.5)), child: c.value == widget.accent.value ? const Icon(Icons.check, color: Colors.white, size: 16) : null)); }))])),
      Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(16), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Display Size', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
          Text(scaleNames[widget.scaleIdx], style: TextStyle(fontSize: 13, color: widget.accent, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(children: [Text('Aa', style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.4))),
            Expanded(child: Slider(value: widget.scaleIdx.toDouble(), min: 0, max: 4, divisions: 4, activeColor: widget.accent, onChanged: (v) => widget.sScale(v.round()))),
            Text('Aa', style: TextStyle(fontSize: 20, color: cs.onSurface.withOpacity(0.4)))])])),
      // ── DATA ──
      _sec('DATA', Icons.storage_rounded, cs),
      _row('Export CSV', Icons.download_rounded, 'Coming soon', () {}, cs, sc: cs.onSurface.withOpacity(0.25)),
      _row('Backup & Restore', Icons.cloud_upload_rounded, 'Coming soon', () {}, cs, sc: cs.onSurface.withOpacity(0.25)),
      // ── ABOUT ──
      _sec('ABOUT', Icons.info_outline_rounded, cs),
      Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.fromLTRB(20, 24, 20, 24), decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: cs.surface),
        child: Column(children: [
          Text('ZENITH', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w800, color: widget.accent, letterSpacing: 2)),
          const SizedBox(height: 4),
          Text('Track Less. Know More.', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4))),
          const SizedBox(height: 20),
          _ir('Version', '1.0.0', cs),
          const SizedBox(height: 8),
          _ir('Built with', 'Flutter & Dart', cs),
          const SizedBox(height: 8),
          _ir('Database', 'zenith_v7', cs),
          const SizedBox(height: 16),
          Text('Created by Siddharth Ganesh', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.3))),
        ])),
      const SizedBox(height: 16),
    ]));
  }
  Widget _sec(String t, IconData ic, ColorScheme cs) => Padding(padding: const EdgeInsets.fromLTRB(20, 20, 20, 6), child: Row(children: [Icon(ic, size: 14, color: cs.onSurface.withOpacity(0.3)), const SizedBox(width: 6), Text(t, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.35), letterSpacing: 1))]));
  Widget _tog(String t, IconData ic, bool v, ValueChanged<bool> fn, ColorScheme cs) => Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface), child: Row(children: [Icon(ic, size: 20, color: cs.onSurface.withOpacity(0.5)), const SizedBox(width: 12), Expanded(child: Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface))), Switch(value: v, onChanged: fn, activeColor: widget.accent)]));
  Widget _row(String t, IconData ic, String s, VoidCallback fn, ColorScheme cs, {Color? sc}) => GestureDetector(onTap: fn, child: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(16), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface), child: Row(children: [Icon(ic, size: 20, color: cs.onSurface.withOpacity(0.5)), const SizedBox(width: 12), Expanded(child: Text(t, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface))), Text(s, style: TextStyle(fontSize: 13, color: sc ?? cs.onSurface.withOpacity(0.4), fontWeight: FontWeight.w600)), const SizedBox(width: 6), Icon(Icons.arrow_forward_ios_rounded, size: 14, color: cs.onSurface.withOpacity(0.2))])));
  Widget _ir(String l, String v, ColorScheme cs) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.5))), Text(v, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.35)))]);
}

// ═══ SHEETS ═══

class _CatSheet extends StatefulWidget {
  final double amount; final String merchant; final Color accent; final Function(String, String, bool) onSelect;
  const _CatSheet({required this.amount, required this.merchant, required this.accent, required this.onSelect});
  @override State<_CatSheet> createState() => _CatSheetState();
}
class _CatSheetState extends State<_CatSheet> {
  String _note = ''; bool _auto = true;
  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme;
    return Container(constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.85), decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12), Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Text('-${fmtAmt(widget.amount)}', style: GoogleFonts.jetBrainsMono(fontSize: 32, fontWeight: FontWeight.w800, color: const Color(0xFFF43F5E))),
        const SizedBox(height: 4), Text('Paid to ${widget.merchant}', style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.6))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: TextField(onChanged: (v) => _note = v, decoration: InputDecoration(hintText: 'Note (optional)', prefixIcon: Icon(Icons.edit_note_rounded, color: cs.onSurface.withOpacity(0.3)), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: Row(children: [Switch(value: _auto, onChanged: (v) => setState(() => _auto = v), activeColor: widget.accent), Expanded(child: Text('Auto-categorize for ${widget.merchant}', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.5))))])),
        const SizedBox(height: 8),
        Flexible(child: GridView.builder(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), shrinkWrap: true,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1.1), itemCount: cats.length,
          itemBuilder: (_, i) { final c = cats[i]; return GestureDetector(onTap: () => widget.onSelect(c.id, _note, _auto),
            child: Container(decoration: BoxDecoration(color: c.color.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.color.withOpacity(0.2))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(c.icon, style: const TextStyle(fontSize: 22)), const SizedBox(height: 4), Text(c.name, style: TextStyle(fontSize: 9, color: cs.onSurface.withOpacity(0.6)), textAlign: TextAlign.center, maxLines: 2)]))); }))]));
  }
}

class _IncCatSheet extends StatefulWidget {
  final double amount; final String merchant; final Color accent; final Function(String, String) onSelect;
  const _IncCatSheet({required this.amount, required this.merchant, required this.accent, required this.onSelect});
  @override State<_IncCatSheet> createState() => _IncCatSheetState();
}
class _IncCatSheetState extends State<_IncCatSheet> {
  String _note = '';
  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme;
    return Container(constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.7), decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12), Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Text('+${fmtAmt(widget.amount)}', style: GoogleFonts.jetBrainsMono(fontSize: 32, fontWeight: FontWeight.w800, color: const Color(0xFF22C55E))),
        const SizedBox(height: 4), Text('From ${widget.merchant}', style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.6))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 0), child: TextField(onChanged: (v) => _note = v, decoration: InputDecoration(hintText: 'Note (optional)', prefixIcon: Icon(Icons.edit_note_rounded, color: cs.onSurface.withOpacity(0.3)), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)))),
        const SizedBox(height: 12),
        Flexible(child: GridView.builder(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), shrinkWrap: true,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1.1), itemCount: iCats.length,
          itemBuilder: (_, i) { final c = iCats[i]; return GestureDetector(onTap: () => widget.onSelect(c.id, _note),
            child: Container(decoration: BoxDecoration(color: c.color.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.color.withOpacity(0.2))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(c.icon, style: const TextStyle(fontSize: 22)), const SizedBox(height: 4), Text(c.name, style: TextStyle(fontSize: 9, color: cs.onSurface.withOpacity(0.6)), textAlign: TextAlign.center, maxLines: 2)]))); }))]));
  }
}

class _AddSheet extends StatefulWidget {
  final Color accent; final ValueChanged<Txn> onAdd;
  const _AddSheet({required this.accent, required this.onAdd});
  @override State<_AddSheet> createState() => _AddSheetState();
}
class _AddSheetState extends State<_AddSheet> {
  bool _exp = true; String _amt = '', _merch = '', _cat = '', _note = '';
  DateTime _date = DateTime.now();
  bool _use24h = false;
  bool _suggested = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (mounted) {
        setState(() => _use24h = p.getBool(PrefsKeys.time24h) ?? false);
      }
    });
  }

  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme; final cl = _exp ? cats : iCats; final ok = _amt.isNotEmpty && _merch.isNotEmpty && _cat.isNotEmpty;
    // P2.7 keyboard UX — wrap with viewInsets padding so the sheet rides the
    // keyboard, and split content/footer so the Add button stays pinned above
    // the keyboard. maxHeight is computed against AVAILABLE space (screen minus
    // keyboard) so the container shrinks rather than overflowing.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final available = MediaQuery.of(context).size.height - bottomInset;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(constraints: BoxConstraints(maxHeight: available * 0.88), decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 12), children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))), const SizedBox(height: 16),
            Text('Add Transaction', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: cs.onSurface)), const SizedBox(height: 14),
            Row(children: [
              Expanded(child: GestureDetector(onTap: () => setState(() { _exp = true; _cat = ''; _suggested = false; }), child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: _exp ? const Color(0xFFF43F5E).withOpacity(0.1) : Colors.transparent, border: Border.all(color: _exp ? const Color(0xFFF43F5E).withOpacity(0.3) : cs.outline.withOpacity(0.1))), child: Center(child: Text('💸 Expense', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _exp ? const Color(0xFFF43F5E) : cs.onSurface.withOpacity(0.4))))))),
              const SizedBox(width: 8),
              Expanded(child: GestureDetector(onTap: () => setState(() { _exp = false; _cat = ''; _suggested = false; }), child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: !_exp ? const Color(0xFF22C55E).withOpacity(0.1) : Colors.transparent, border: Border.all(color: !_exp ? const Color(0xFF22C55E).withOpacity(0.3) : cs.outline.withOpacity(0.1))), child: Center(child: Text('💰 Income', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: !_exp ? const Color(0xFF22C55E) : cs.onSurface.withOpacity(0.4))))))),
            ]), const SizedBox(height: 14),
            TextField(keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (v) => setState(() => _amt = v), style: GoogleFonts.jetBrainsMono(fontSize: 28, fontWeight: FontWeight.w800),
              decoration: InputDecoration(hintText: '₹ 0', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
            const SizedBox(height: 10),
            TextField(onChanged: (v) async { setState(() { _merch = v; _suggested = false; }); if (_exp && v.trim().length >= 2 && _cat.isEmpty) { final auto = await Db.getAutoCat(v.trim()); if (mounted && auto != null && _cat.isEmpty) setState(() { _cat = auto; _suggested = true; }); } }, decoration: InputDecoration(hintText: _exp ? 'Merchant' : 'Source', suffixIcon: _suggested ? Tooltip(message: 'Suggested from history', child: Icon(Icons.auto_awesome_rounded, size: 16, color: widget.accent)) : null, filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
            const SizedBox(height: 10),
            TextField(onChanged: (v) => _note = v, decoration: InputDecoration(hintText: 'Note (optional)', prefixIcon: Icon(Icons.edit_note_rounded, color: cs.onSurface.withOpacity(0.3)), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
            const SizedBox(height: 10),
            Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cs.outline.withOpacity(0.05), border: Border.all(color: cs.outline.withOpacity(0.08))), child: Row(children: [
              Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () async { HapticFeedback.lightImpact(); final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365 * 5)), builder: (ctx, child) => Theme(data: Theme.of(ctx).copyWith(colorScheme: ColorScheme.dark(primary: widget.accent, onPrimary: Colors.white, surface: cs.surface, onSurface: cs.onSurface)), child: child!)); if (picked != null) setState(() => _date = DateTime(picked.year, picked.month, picked.day, _date.hour, _date.minute, _date.second)); }, child: Padding(padding: const EdgeInsets.fromLTRB(14, 12, 10, 12), child: Row(children: [Icon(Icons.calendar_today_rounded, size: 15, color: widget.accent), const SizedBox(width: 10), Flexible(child: Text(DateFormat('EEE, d MMM yyyy').format(_date), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: cs.onSurface), overflow: TextOverflow.ellipsis))])))),
              Container(width: 1, height: 22, color: cs.outline.withOpacity(0.1)),
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: _pickTime, child: Padding(padding: const EdgeInsets.fromLTRB(12, 12, 14, 12), child: Row(children: [Icon(Icons.access_time_rounded, size: 15, color: widget.accent), const SizedBox(width: 8), Text(fmtTxnTime(_date), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: cs.onSurface))]))),
            ])),
            const SizedBox(height: 14),
            GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 7, crossAxisSpacing: 7, childAspectRatio: 1.15), itemCount: cl.length,
              itemBuilder: (_, i) { final c = cl[i]; final sel = _cat == c.id;
                return GestureDetector(onTap: () => setState(() { _cat = c.id; _suggested = false; }), child: Container(decoration: BoxDecoration(color: sel ? c.color.withOpacity(0.15) : cs.outline.withOpacity(0.04), borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? c.color.withOpacity(0.4) : cs.outline.withOpacity(0.08))),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(c.icon, style: const TextStyle(fontSize: 20)), const SizedBox(height: 3), Text(c.name, style: TextStyle(fontSize: 9, color: sel ? c.color : cs.onSurface.withOpacity(0.5), fontWeight: sel ? FontWeight.w700 : FontWeight.w400), textAlign: TextAlign.center, maxLines: 2)]))); }),
            const SizedBox(height: 8),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(18, 6, 18, 18), child: SizedBox(width: double.infinity, child: ElevatedButton(onPressed: ok ? () {
            final amount = double.tryParse(_amt.replaceAll(',','').replaceAll(' ','')) ?? 0;
            if (amount <= 0) return;
            widget.onAdd(Txn(id: DateTime.now().millisecondsSinceEpoch.toString(), amount: amount, merchant: _merch, category: _cat, account: 'gpay', type: _exp ? 'expense' : 'income', date: _date, note: _note));
          } : null,
            style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.all(16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: Text('Add ${_exp ? "Expense" : "Income"}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))))),
        ])));
  }
  Future<void> _pickTime() async {
    HapticFeedback.lightImpact();
    final cs = Theme.of(context).colorScheme;
    DateTime temp = _date;
    await showModalBottomSheet(context: context, backgroundColor: cs.surface, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))), builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 12),
      Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))),
      const SizedBox(height: 10),
      Text('Select Time', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: cs.onSurface)),
      const SizedBox(height: 4),
      SizedBox(height: 220, child: CupertinoTheme(data: CupertinoThemeData(brightness: Theme.of(ctx).brightness, textTheme: CupertinoTextThemeData(dateTimePickerTextStyle: GoogleFonts.jetBrainsMono(fontSize: 20, fontWeight: FontWeight.w600, color: cs.onSurface))), child: CupertinoDatePicker(mode: CupertinoDatePickerMode.time, initialDateTime: _date, use24hFormat: _use24h, onDateTimeChanged: (d) => temp = d))),
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 18), child: SizedBox(width: double.infinity, child: ElevatedButton(onPressed: () { HapticFeedback.selectionClick(); setState(() => _date = DateTime(_date.year, _date.month, _date.day, temp.hour, temp.minute)); Navigator.pop(ctx); }, style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.all(14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14))))),
    ])));
  }
}

class _EditSheet extends StatefulWidget {
  final Txn txn; final Color accent; final ValueChanged<Txn> onSave; final VoidCallback onDelete, onStopAuto, onStartAuto;
  const _EditSheet({required this.txn, required this.accent, required this.onSave, required this.onDelete, required this.onStopAuto, required this.onStartAuto});
  @override State<_EditSheet> createState() => _EditSheetState();
}
class _EditSheetState extends State<_EditSheet> {
  late String _cat, _note, _amt; late TextEditingController _nc, _ac; late DateTime _date; bool _use24h = false; bool _learning = true;
  @override void initState() { super.initState(); _cat = widget.txn.category; _note = widget.txn.note; _nc = TextEditingController(text: _note); _date = widget.txn.date;
    _amt = widget.txn.amount == widget.txn.amount.truncateToDouble() ? widget.txn.amount.toInt().toString() : widget.txn.amount.toString();
    _ac = TextEditingController(text: _amt);
    SharedPreferences.getInstance().then((p) { if (mounted) setState(() => _use24h = p.getBool(PrefsKeys.time24h) ?? false); });
    Db.isAutoEnabled(widget.txn.merchant).then((on) { if (mounted) setState(() => _learning = on); }); }
  @override void dispose() { _nc.dispose(); _ac.dispose(); super.dispose(); }
  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme; final isI = widget.txn.type == 'income'; final cl = isI ? iCats : cats;
    // P2.7 keyboard UX — mirror _AddSheet: viewInsets padding outside, content
    // scrolls in a Flexible ListView, Save Changes pinned as a fixed footer.
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final available = MediaQuery.of(context).size.height - bottomInset;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(constraints: BoxConstraints(maxHeight: available * 0.86), decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 12), children: [
            Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))), const SizedBox(height: 16),
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Edit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: cs.onSurface)),
              Row(children: [TextButton(onPressed: () { _learning ? HapticFeedback.lightImpact() : HapticFeedback.mediumImpact(); _learning ? widget.onStopAuto() : widget.onStartAuto(); }, child: Text(_learning ? 'Stop learning' : 'Start learning again', style: TextStyle(color: _learning ? cs.onSurface.withOpacity(0.4) : const Color(0xFF22C55E), fontWeight: _learning ? FontWeight.w500 : FontWeight.w700, fontSize: 12))),
                TextButton(onPressed: () { HapticFeedback.mediumImpact(); widget.onDelete(); }, child: const Text('Delete', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.w700, fontSize: 12)))])]),
            const SizedBox(height: 8),
            TextField(controller: _ac, keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (v) => setState(() => _amt = v), style: GoogleFonts.jetBrainsMono(fontSize: 26, fontWeight: FontWeight.w800, color: isI ? const Color(0xFF22C55E) : cs.onSurface),
              decoration: InputDecoration(prefixText: isI ? '+ ₹ ' : '- ₹ ', prefixStyle: GoogleFonts.jetBrainsMono(fontSize: 26, fontWeight: FontWeight.w800, color: isI ? const Color(0xFF22C55E) : cs.onSurface), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12))),
            const SizedBox(height: 6),
            Text(widget.txn.merchant, style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.5))),
            const SizedBox(height: 12),
            Container(decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cs.outline.withOpacity(0.05), border: Border.all(color: cs.outline.withOpacity(0.08))), child: Row(children: [
              Expanded(child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () async { HapticFeedback.lightImpact(); final picked = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime.now().add(const Duration(days: 365 * 5)), builder: (ctx, child) => Theme(data: Theme.of(ctx).copyWith(colorScheme: ColorScheme.dark(primary: widget.accent, onPrimary: Colors.white, surface: cs.surface, onSurface: cs.onSurface)), child: child!)); if (picked != null) setState(() => _date = DateTime(picked.year, picked.month, picked.day, _date.hour, _date.minute, _date.second)); }, child: Padding(padding: const EdgeInsets.fromLTRB(14, 12, 10, 12), child: Row(children: [Icon(Icons.calendar_today_rounded, size: 15, color: widget.accent), const SizedBox(width: 10), Flexible(child: Text(DateFormat('EEE, d MMM yyyy').format(_date), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: cs.onSurface), overflow: TextOverflow.ellipsis))])))),
              Container(width: 1, height: 22, color: cs.outline.withOpacity(0.1)),
              GestureDetector(behavior: HitTestBehavior.opaque, onTap: _pickTime, child: Padding(padding: const EdgeInsets.fromLTRB(12, 12, 14, 12), child: Row(children: [Icon(Icons.access_time_rounded, size: 15, color: widget.accent), const SizedBox(width: 8), Text(fmtTxnTime(_date), style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: cs.onSurface))]))),
            ])),
            const SizedBox(height: 12),
            TextField(controller: _nc, onChanged: (v) => _note = v, decoration: InputDecoration(hintText: 'Note', prefixIcon: Icon(Icons.edit_note_rounded, color: cs.onSurface.withOpacity(0.3)), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
            const SizedBox(height: 12),
            GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 7, crossAxisSpacing: 7, childAspectRatio: 1.15), itemCount: cl.length,
              itemBuilder: (_, i) { final c = cl[i]; final sel = _cat == c.id;
                return GestureDetector(onTap: () => setState(() => _cat = c.id), child: Container(decoration: BoxDecoration(color: sel ? c.color.withOpacity(0.15) : cs.outline.withOpacity(0.04), borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? c.color.withOpacity(0.4) : cs.outline.withOpacity(0.08))),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(c.icon, style: const TextStyle(fontSize: 20)), const SizedBox(height: 3), Text(c.name, style: TextStyle(fontSize: 9, color: sel ? c.color : cs.onSurface.withOpacity(0.5), fontWeight: sel ? FontWeight.w700 : FontWeight.w400), textAlign: TextAlign.center, maxLines: 2)]))); }),
            const SizedBox(height: 6),
          ])),
          Padding(padding: const EdgeInsets.fromLTRB(18, 6, 18, 18), child: SizedBox(width: double.infinity, child: ElevatedButton(onPressed: () { final amount = double.tryParse(_amt.replaceAll(',', '').replaceAll(' ', '')) ?? widget.txn.amount; if (amount <= 0) return; widget.onSave(Txn(id: widget.txn.id, amount: amount, merchant: widget.txn.merchant, category: _cat, account: widget.txn.account, type: widget.txn.type, date: _date, note: _note)); },
            style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.all(16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
            child: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15))))),
        ])));
  }
  Future<void> _pickTime() async {
    HapticFeedback.lightImpact();
    final cs = Theme.of(context).colorScheme;
    DateTime temp = _date;
    await showModalBottomSheet(context: context, backgroundColor: cs.surface, shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(24))), builder: (ctx) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      const SizedBox(height: 12),
      Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))),
      const SizedBox(height: 10),
      Text('Select Time', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: cs.onSurface)),
      const SizedBox(height: 4),
      SizedBox(height: 220, child: CupertinoTheme(data: CupertinoThemeData(brightness: Theme.of(ctx).brightness, textTheme: CupertinoTextThemeData(dateTimePickerTextStyle: GoogleFonts.jetBrainsMono(fontSize: 20, fontWeight: FontWeight.w600, color: cs.onSurface))), child: CupertinoDatePicker(mode: CupertinoDatePickerMode.time, initialDateTime: _date, use24hFormat: _use24h, onDateTimeChanged: (d) => temp = d))),
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 18), child: SizedBox(width: double.infinity, child: ElevatedButton(onPressed: () { HapticFeedback.selectionClick(); setState(() => _date = DateTime(_date.year, _date.month, _date.day, temp.hour, temp.minute)); Navigator.pop(ctx); }, style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.all(14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))), child: const Text('Done', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 14))))),
    ])));
  }
}