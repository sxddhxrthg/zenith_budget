import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;
import 'package:firebase_core/firebase_core.dart';
import 'auth_bypass.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try { await Firebase.initializeApp(); } catch (_) {}
  runApp(const ZenithApp());
}

// ═══════════════════════════════════════
// DATABASE — amounts stored as-is, no rounding tricks
// Total monthly budget in SharedPreferences (single int, never split)
// Category budgets in SQLite ONLY if user explicitly sets them
// ═══════════════════════════════════════

class Db {
  static Database? _db;
  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await openDatabase(p.join(await getDatabasesPath(), 'zenith_v7.db'), version: 1, onCreate: (db, v) async {
      await db.execute('CREATE TABLE txns(id TEXT PRIMARY KEY, amount REAL, merchant TEXT, category TEXT, account TEXT, type TEXT, date TEXT, note TEXT)');
      await db.execute('CREATE TABLE merchant_map(merchant TEXT PRIMARY KEY, category TEXT, auto_enabled INTEGER DEFAULT 1)');
      await db.execute('CREATE TABLE cat_budgets(category TEXT PRIMARY KEY, budget INTEGER)');
    });
    return _db!;
  }
  static Future<void> insTxn(Map<String, dynamic> t) async => (await db).insert('txns', t, conflictAlgorithm: ConflictAlgorithm.replace);
  static Future<void> updTxn(Map<String, dynamic> t) async => (await db).update('txns', t, where: 'id=?', whereArgs: [t['id']]);
  static Future<void> delTxn(String id) async => (await db).delete('txns', where: 'id=?', whereArgs: [id]);
  static Future<List<Map<String, dynamic>>> allTxns() async => (await db).query('txns', orderBy: 'date DESC');
  static Future<String?> getAutoCat(String m) async { final r = await (await db).query('merchant_map', where: 'merchant=? AND auto_enabled=1', whereArgs: [m.toLowerCase()]); return r.isNotEmpty ? r.first['category'] as String : null; }
  static Future<void> setAutoCat(String m, String c) async => (await db).insert('merchant_map', {'merchant': m.toLowerCase(), 'category': c, 'auto_enabled': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
  static Future<void> stopAuto(String m) async => (await db).update('merchant_map', {'auto_enabled': 0}, where: 'merchant=?', whereArgs: [m.toLowerCase()]);
  static Future<void> setCatBudget(String cat, int amt) async => (await db).insert('cat_budgets', {'category': cat, 'budget': amt}, conflictAlgorithm: ConflictAlgorithm.replace);
  static Future<void> delCatBudget(String cat) async => (await db).delete('cat_budgets', where: 'category=?', whereArgs: [cat]);
  static Future<Map<String, int>> catBudgets() async { final r = await (await db).query('cat_budgets'); return { for (var row in r) row['category'] as String: (row['budget'] as num).toInt() }; }
}

Future<int> getMonthlyBudget() async => (await SharedPreferences.getInstance()).getInt('monthly_budget') ?? 0;
Future<void> setMonthlyBudget(int v) async => (await SharedPreferences.getInstance()).setInt('monthly_budget', v);

// ═══ NATIVE BRIDGE ═══

class NB {
  static const _m = MethodChannel('com.zenith.budget/methods');
  static const _e = EventChannel('com.zenith.budget/transactions');
  static Future<bool> notifOk() async { try { return await _m.invokeMethod('isNotificationAccessGranted') ?? false; } catch (_) { return false; } }
  static Future<void> openNotif() async { try { await _m.invokeMethod('openNotificationAccessSettings'); } catch (_) {} }
  static Stream<Map<String, dynamic>> get stream => _e.receiveBroadcastStream().map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{});
}

// ═══ MODELS ═══

class Txn {
  String id; double amount; String merchant, category, account, type, note; DateTime date;
  Txn({required this.id, required this.amount, required this.merchant, required this.category, required this.account, required this.type, required this.date, this.note = ''});
  Map<String, dynamic> toMap() => {'id': id, 'amount': amount, 'merchant': merchant, 'category': category, 'account': account, 'type': type, 'date': date.toIso8601String(), 'note': note};
  factory Txn.fromMap(Map<String, dynamic> m) => Txn(id: m['id'], amount: (m['amount'] as num).toDouble(), merchant: m['merchant'] ?? '', category: m['category'] ?? 'other', account: m['account'] ?? 'gpay', type: m['type'] ?? 'expense', date: DateTime.tryParse(m['date'] ?? '') ?? DateTime.now(), note: m['note'] ?? '');
}

class Cat { final String id, name, icon; final Color color; Cat(this.id, this.name, this.icon, this.color); }
final cats = <Cat>[Cat("food","Food & Dining","🍕",const Color(0xFFFF6B35)),Cat("transport","Transport","🚗",const Color(0xFF00D4FF)),Cat("shopping","Shopping","🛍️",const Color(0xFFA855F7)),Cat("entertainment","Entertainment","🎬",const Color(0xFFF43F5E)),Cat("groceries","Groceries","🥦",const Color(0xFF22C55E)),Cat("bills","Bills & Utilities","💡",const Color(0xFFEAB308)),Cat("health","Health","💊",const Color(0xFF06B6D4)),Cat("education","Education","📚",const Color(0xFF8B5CF6)),Cat("subscriptions","Subscriptions","📱",const Color(0xFFEC4899)),Cat("travel","Travel","✈️",const Color(0xFFF97316)),Cat("rent","Rent & Housing","🏠",const Color(0xFF14B8A6)),Cat("savings","Savings","💰",const Color(0xFF10B981)),Cat("personal","Personal","✨",const Color(0xFFD946EF)),Cat("gifts","Gifts","🎁",const Color(0xFFF59E0B)),Cat("other","Other","📌",const Color(0xFF64748B))];
final iCats = <Cat>[Cat("salary","Salary","💼",const Color(0xFF22C55E)),Cat("freelance","Freelance","💻",const Color(0xFF3B82F6)),Cat("business","Business","🏢",const Color(0xFF8B5CF6)),Cat("investment","Investment","📈",const Color(0xFF10B981)),Cat("refund","Refund","↩️",const Color(0xFF06B6D4)),Cat("other_income","Other","💵",const Color(0xFF64748B))];
final accents = [const Color(0xFF00D4FF),const Color(0xFFA855F7),const Color(0xFF10B981),const Color(0xFFF43F5E),const Color(0xFFF59E0B),const Color(0xFF3B82F6),const Color(0xFF84CC16),const Color(0xFFEC4899)];
const _scales = [0.8, 0.9, 1.0, 1.15, 1.3];
const _scaleNames = ['Very Small', 'Small', 'Medium', 'Big', 'Very Big'];

String fmtAmt(double n) => NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2).format(n);
String fmtInt(int n) => NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0).format(n);
Cat? fCat(String id) => [...cats, ...iCats].where((c) => c.id == id).firstOrNull;

// ═══ APP ═══

class ZenithApp extends StatefulWidget { const ZenithApp({super.key}); @override State<ZenithApp> createState() => _ZenithAppState(); }
class _ZenithAppState extends State<ZenithApp> {
  ThemeMode _mode = ThemeMode.dark; Color _accent = const Color(0xFF00D4FF); int _scaleIdx = 2;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { final p = await SharedPreferences.getInstance(); setState(() { _mode = p.getString('theme') == 'light' ? ThemeMode.light : ThemeMode.dark; _accent = accents[(p.getInt('accent') ?? 0).clamp(0, 7)]; _scaleIdx = (p.getInt('font_scale') ?? 2).clamp(0, 4); }); }
  void _tTheme() async { final p = await SharedPreferences.getInstance(); setState(() { _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark; p.setString('theme', _mode == ThemeMode.light ? 'light' : 'dark'); }); }
  void _sAccent(int i) async { final p = await SharedPreferences.getInstance(); setState(() { _accent = accents[i.clamp(0, 7)]; p.setInt('accent', i); }); }
  void _sScale(int i) async { final p = await SharedPreferences.getInstance(); setState(() { _scaleIdx = i.clamp(0, 4); p.setInt('font_scale', _scaleIdx); }); }

  @override Widget build(BuildContext context) {
    final scale = _scales[_scaleIdx];
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
  StreamSubscription? _sub;
  bool _notifOk = false, _loading = true, _asked = false;

  @override void initState() { super.initState(); _load(); _listen(); _checkNotif();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(systemNavigationBarColor: Colors.transparent, systemNavigationBarDividerColor: Colors.transparent)); }

  Future<void> _load() async {
    final rows = await Db.allTxns();
    final cb = await Db.catBudgets();
    final mb = await getMonthlyBudget();
    if (mounted) setState(() { _txns = rows.map((m) => Txn.fromMap(m)).toList(); _catB = cb; _monthBud = mb; _loading = false; });
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
        if (auto != null) { await Db.insTxn(Txn(id: _uid(), amount: amt, merchant: merch, category: auto, account: acc, type: 'expense', date: DateTime.now()).toMap()); await _load();
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Auto: ${fmtAmt(amt)} → ${fCat(auto)?.name}'), duration: const Duration(seconds: 3)));
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
      await Db.insTxn(Txn(id: _uid(), amount: amt, merchant: merch, category: catId, account: acc, type: 'expense', date: DateTime.now(), note: note).toMap());
      if (auto) await Db.setAutoCat(merch, catId); await _load(); if (ctx.mounted) Navigator.pop(ctx); }));

  void _showIncCat(double amt, String merch, String acc) => showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
    builder: (ctx) => _IncCatSheet(amount: amt, merchant: merch, accent: widget.accent, onSelect: (catId, note) async {
      await Db.insTxn(Txn(id: _uid(), amount: amt, merchant: merch, category: catId, account: acc, type: 'income', date: DateTime.now(), note: note).toMap());
      await _load(); if (ctx.mounted) Navigator.pop(ctx); }));

  void _showAdd() => showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
    builder: (ctx) => _AddSheet(accent: widget.accent, onAdd: (t) async { await Db.insTxn(t.toMap()); await _load(); if (ctx.mounted) Navigator.pop(ctx); }));

  void _showEdit(Txn t) => showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
    builder: (ctx) => _EditSheet(txn: t, accent: widget.accent,
      onSave: (u) async { await Db.updTxn(u.toMap()); await _load(); if (ctx.mounted) Navigator.pop(ctx); },
      onDelete: () async { await Db.delTxn(t.id); await _load(); if (ctx.mounted) Navigator.pop(ctx); },
      onStopAuto: () async { await Db.stopAuto(t.merchant); await _load(); if (ctx.mounted) Navigator.pop(ctx);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Auto stopped for ${t.merchant}'))); }));

  void _delTxn(Txn t) async { HapticFeedback.mediumImpact(); await Db.delTxn(t.id); await _load(); }

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

  double get tExp => _txns.where((t) => t.type == 'expense').fold(0.0, (s, t) => s + t.amount);
  double get tInc => _txns.where((t) => t.type == 'income').fold(0.0, (s, t) => s + t.amount);

  @override void dispose() { _sub?.cancel(); super.dispose(); }
  @override Widget build(BuildContext context) {
    if (_loading) return Scaffold(body: Center(child: CircularProgressIndicator(color: widget.accent)));
    final cs = Theme.of(context).colorScheme;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final tabs = [
      _Home(txns: _txns, catB: _catB, monthBud: _monthBud, accent: widget.accent, name: widget.name, tExp: tExp, tInc: tInc, notifOk: _notifOk, onNotif: () { NB.openNotif(); Future.delayed(const Duration(seconds: 3), _checkNotif); }, onAdd: _showAdd, onTap: _showEdit, onEditBud: _editMonthBud, onDelete: _delTxn),
      _Activity(txns: _txns, onTap: _showEdit, onDelete: _delTxn),
      _BudgetsTab(txns: _txns, catB: _catB, monthBud: _monthBud, accent: widget.accent, onEditTotal: _editMonthBud, onEditCat: _editCatBud),
      _StatsTab(txns: _txns, accent: widget.accent, tExp: tExp, tInc: tInc, catB: _catB, monthBud: _monthBud),
      _Settings(accent: widget.accent, isDark: widget.isDark, notifOk: _notifOk, scaleIdx: widget.scaleIdx, tTheme: widget.tTheme, sAccent: widget.sAccent, sScale: widget.sScale, onNotif: () { NB.openNotif(); Future.delayed(const Duration(seconds: 3), _checkNotif); }),
    ];
    return Scaffold(body: Stack(children: [
      tabs[_tab],
      Positioned(right: 20, bottom: bottomPad + 76, child: GestureDetector(onTap: () { HapticFeedback.lightImpact(); _showAdd(); },
        child: Container(width: 52, height: 52, decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: widget.accent, boxShadow: [BoxShadow(color: widget.accent.withOpacity(0.3), blurRadius: 12, offset: const Offset(0, 4))]),
          child: const Icon(Icons.add_rounded, color: Colors.white, size: 24)))),
      Positioned(left: 20, right: 20, bottom: bottomPad + 12, child: Container(decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(28), boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 24, offset: const Offset(0, 4))]),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10), child: Row(mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: List.generate(5, (i) { final icons = [Icons.home_rounded, Icons.swap_vert_rounded, Icons.pie_chart_rounded, Icons.analytics_rounded, Icons.settings_rounded]; final sel = _tab == i;
            return GestureDetector(onTap: () { HapticFeedback.lightImpact(); setState(() => _tab = i); }, behavior: HitTestBehavior.opaque,
              child: AnimatedContainer(duration: const Duration(milliseconds: 200), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: sel ? widget.accent.withOpacity(0.12) : Colors.transparent),
                child: Icon(icons[i], size: 24, color: sel ? widget.accent : cs.onSurface.withOpacity(0.35)))); })))))]));
  }
}

// ═══ PAINTERS ═══

class _PiePainter extends CustomPainter {
  final List<MapEntry<Cat, double>> data; final double total; final Color bg;
  _PiePainter(this.data, this.total, this.bg);
  @override void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2); final r = size.width / 2 - 2; double a = -math.pi / 2;
    for (var e in data) { final sw = total > 0 ? (e.value / total) * 2 * math.pi : 0.0; canvas.drawArc(Rect.fromCircle(center: c, radius: r), a, sw, true, Paint()..color = e.key.color); a += sw; }
    canvas.drawCircle(c, r * 0.55, Paint()..color = bg);
  }
  @override bool shouldRepaint(covariant CustomPainter o) => true;
}

class _TrendPainter extends CustomPainter {
  final List<double> pts; final Color color;
  _TrendPainter(this.pts, this.color);
  @override void paint(Canvas canvas, Size size) {
    if (pts.length < 2) return; final mx = pts.reduce(math.max); if (mx == 0) return;
    final lp = Paint()..color = color..strokeWidth = 2..style = PaintingStyle.stroke..strokeCap = StrokeCap.round;
    final fp = Paint()..shader = LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withOpacity(0.25), color.withOpacity(0.0)]).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    final gp = Paint()..color = color.withOpacity(0.06)..strokeWidth = 0.5;
    for (int i = 1; i < 4; i++) canvas.drawLine(Offset(0, size.height * i / 4), Offset(size.width, size.height * i / 4), gp);
    final path = Path(); final fill = Path();
    for (int i = 0; i < pts.length; i++) {
      final x = size.width * i / (pts.length - 1); final y = size.height * 0.92 - (pts[i] / mx * size.height * 0.85);
      if (i == 0) { path.moveTo(x, y); fill.moveTo(x, size.height); fill.lineTo(x, y); } else { path.lineTo(x, y); fill.lineTo(x, y); }
      if (i == pts.length - 1) canvas.drawCircle(Offset(x, y), 3.5, Paint()..color = color);
    }
    fill.lineTo(size.width, size.height); fill.close();
    canvas.drawPath(fill, fp); canvas.drawPath(path, lp);
    final step = pts.length > 15 ? 5 : pts.length > 7 ? 3 : 1;
    for (int i = 0; i < pts.length; i += step) {
      final x = size.width * i / (pts.length - 1);
      final tp = TextPainter(text: TextSpan(text: '${i + 1}', style: TextStyle(fontSize: 7, color: color.withOpacity(0.35))), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, Offset(x - tp.width / 2, size.height + 2));
    }
  }
  @override bool shouldRepaint(covariant CustomPainter o) => true;
}

// ═══ HELPERS ═══

Widget _tile(Txn t, ColorScheme cs, {VoidCallback? onTap}) {
  final c = fCat(t.category); final isI = t.type == 'income';
  return GestureDetector(onTap: onTap, child: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
    child: Row(children: [
      Container(width: 44, height: 44, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: (c?.color ?? const Color(0xFF64748B)).withOpacity(0.12)), child: Center(child: Text(c?.icon ?? '📌', style: const TextStyle(fontSize: 20)))),
      const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(t.merchant, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
        const SizedBox(height: 3),
        Text('${c?.name ?? "Other"} · ${DateFormat.jm().format(t.date)}', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4))),
        if (t.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(t.note, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.3), fontStyle: FontStyle.italic), maxLines: 1, overflow: TextOverflow.ellipsis))])),
      Text(isI ? '+${fmtAmt(t.amount)}' : '-${fmtAmt(t.amount)}', style: GoogleFonts.jetBrainsMono(fontSize: 15, fontWeight: FontWeight.w800, color: isI ? const Color(0xFF34D399) : const Color(0xFFEF4444)))])));
}

List<Widget> _grouped(List<Txn> txns, ColorScheme cs, ValueChanged<Txn> onTap, {int limit = 20, ValueChanged<Txn>? onDelete}) {
  final w = <Widget>[]; String? last;
  for (final t in txns.take(limit)) {
    final d = DateFormat('EEEE, d MMM').format(t.date);
    if (d != last) { last = d; final l = DateUtils.isSameDay(t.date, DateTime.now()) ? 'Today' : DateUtils.isSameDay(t.date, DateTime.now().subtract(const Duration(days: 1))) ? 'Yesterday' : d;
      w.add(Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 6), child: Text(l, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.45))))); }
    w.add(Dismissible(key: Key(t.id),
      background: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: const Color(0xFF3B82F6).withOpacity(0.15)),
        alignment: Alignment.centerLeft, padding: const EdgeInsets.only(left: 24), child: const Icon(Icons.edit_rounded, color: Color(0xFF3B82F6), size: 22)),
      secondaryBackground: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: const Color(0xFFEF4444).withOpacity(0.15)),
        alignment: Alignment.centerRight, padding: const EdgeInsets.only(right: 24), child: const Icon(Icons.delete_rounded, color: Color(0xFFEF4444), size: 22)),
      confirmDismiss: (dir) async { if (dir == DismissDirection.startToEnd) { HapticFeedback.lightImpact(); onTap(t); return false; } return true; },
      onDismissed: (_) => onDelete?.call(t),
      child: _tile(t, cs, onTap: () => onTap(t)))); }
  return w;
}

// ═══ HOME ═══

class _Home extends StatelessWidget {
  final List<Txn> txns; final Map<String, int> catB; final int monthBud; final Color accent; final String name; final bool notifOk;
  final double tExp, tInc; final VoidCallback onNotif, onAdd, onEditBud; final ValueChanged<Txn> onTap, onDelete;
  const _Home({required this.txns, required this.catB, required this.monthBud, required this.accent, required this.name, required this.notifOk, required this.tExp, required this.tInc, required this.onNotif, required this.onAdd, required this.onTap, required this.onEditBud, required this.onDelete});

  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = monthBud > 0 ? (tExp / monthBud).clamp(0.0, 1.0) : 0.0;
    final bal = tInc - tExp;
    final daysLeft = DateUtils.getDaysInMonth(DateTime.now().year, DateTime.now().month) - DateTime.now().day;
    final left = (monthBud - tExp).clamp(0.0, double.infinity);
    final dailyAllow = daysLeft > 0 && monthBud > 0 ? left / daysLeft : 0.0;

    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 0), child: Text('Hi, $name 👋', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface))),
      if (!notifOk) GestureDetector(onTap: onNotif, child: Container(margin: const EdgeInsets.fromLTRB(16, 10, 16, 0), padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: const Color(0xFFF43F5E).withOpacity(0.08)),
        child: Row(children: [const Icon(Icons.notifications_active_rounded, color: Color(0xFFF43F5E), size: 18), const SizedBox(width: 8), Expanded(child: Text('Enable GPay auto-detection', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: cs.onSurface)))]))),
      GestureDetector(onTap: onEditBud, child: Container(margin: const EdgeInsets.fromLTRB(16, 12, 16, 0), padding: const EdgeInsets.all(22),
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
                    if (daysLeft > 0 && left > 0) Text('${fmtAmt(dailyAllow)}/day · $daysLeft days left', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4)))])]))])
          : Column(children: [
              const SizedBox(height: 8),
              Icon(Icons.account_balance_wallet_rounded, size: 32, color: accent.withOpacity(0.5)),
              const SizedBox(height: 10),
              Text('Set your monthly budget', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
              const SizedBox(height: 4),
              Text('Tap to get started', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4))),
              const SizedBox(height: 8)]))),
      Container(margin: const EdgeInsets.fromLTRB(16, 8, 16, 0), padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12), decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: cs.surface),
        child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Balance', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))), Text(fmtAmt(bal), style: GoogleFonts.jetBrainsMono(fontSize: 22, fontWeight: FontWeight.w800, color: bal >= 0 ? cs.onSurface : const Color(0xFFF43F5E)))]),
          Row(children: [_ms('In', '+${fmtAmt(tInc)}', const Color(0xFF22C55E), cs), const SizedBox(width: 14), _ms('Out', '-${fmtAmt(tExp)}', const Color(0xFFF43F5E), cs)])])),
      if (txns.isNotEmpty) Container(margin: const EdgeInsets.fromLTRB(16, 10, 16, 0), padding: const EdgeInsets.all(12), decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: accent.withOpacity(0.06)),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('💡', style: TextStyle(fontSize: 14)), const SizedBox(width: 8), Expanded(child: Text(_ins(), style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.65), height: 1.4)))])),
      ..._grouped(txns, cs, onTap, limit: 20, onDelete: onDelete),
      if (txns.isEmpty) Padding(padding: const EdgeInsets.fromLTRB(32, 48, 32, 32), child: Column(children: [
        Icon(Icons.receipt_long_rounded, size: 48, color: cs.onSurface.withOpacity(0.12)),
        const SizedBox(height: 16),
        Text('No transactions yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.4))),
        const SizedBox(height: 6),
        Text('Your spending will appear here\nautomatically from GPay', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.25)))])),
    ]));
  }

  Widget _kv(String l, String v, Color c, ColorScheme cs) => Padding(padding: const EdgeInsets.only(bottom: 2), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))), Text(v, style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: c))]));
  Widget _ms(String l, String v, Color c, ColorScheme cs) => Column(crossAxisAlignment: CrossAxisAlignment.end, children: [Text(l, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.35))), Text(v, style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: c))]);
  String _ins() {
    final now = DateTime.now(); final dp = now.day; final dl = DateUtils.getDaysInMonth(now.year, now.month) - dp;
    final da = dp > 0 && tExp > 0 ? tExp / dp : 0.0;
    final top = cats.map((c) => MapEntry(c, txns.where((t) => t.type == 'expense' && t.date.month == now.month && t.category == c.id).fold(0.0, (s, t) => s + t.amount))).where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    if (top.isEmpty) return 'No spending this month yet. Your insights will appear as you spend.';
    final p = <String>[];
    if (monthBud > 0) { final proj = da * DateUtils.getDaysInMonth(now.year, now.month); p.add(proj > monthBud * 1.1 ? 'At this pace: ${fmtAmt(proj)} — ${((proj / monthBud - 1) * 100).round()}% over budget.' : 'On track — ${fmtAmt(monthBud - tExp)} left, $dl days.'); }
    p.add('Top: ${top.first.key.icon} ${top.first.key.name} ${fmtAmt(top.first.value)}.');
    if (da > 0) p.add('Avg: ${fmtAmt(da)}/day.');
    return p.join(' ');
  }
}

// ═══ ACTIVITY ═══

class _Activity extends StatelessWidget {
  final List<Txn> txns; final ValueChanged<Txn> onTap, onDelete;
  const _Activity({required this.txns, required this.onTap, required this.onDelete});
  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme;
    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 4), child: Text('Activity', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface))),
      Padding(padding: const EdgeInsets.fromLTRB(20, 0, 20, 8), child: Text('${txns.length} transaction${txns.length == 1 ? '' : 's'}', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4)))),
      if (txns.isEmpty) Padding(padding: const EdgeInsets.fromLTRB(32, 48, 32, 32), child: Column(children: [
        Icon(Icons.swap_vert_rounded, size: 48, color: cs.onSurface.withOpacity(0.12)),
        const SizedBox(height: 16),
        Text('No activity yet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.4))),
        const SizedBox(height: 6),
        Text('Transactions will show up here\nas you spend', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.25)))])),
      ..._grouped(txns, cs, onTap, limit: 200, onDelete: onDelete)]));
  }
}

// ═══ BUDGETS ═══

class _BudgetsTab extends StatelessWidget {
  final List<Txn> txns; final Map<String, int> catB; final int monthBud; final Color accent; final VoidCallback onEditTotal; final ValueChanged<String> onEditCat;
  const _BudgetsTab({required this.txns, required this.catB, required this.monthBud, required this.accent, required this.onEditTotal, required this.onEditCat});
  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme;
    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 14), child: Text('Budgets', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface))),
      GestureDetector(onTap: onEditTotal, child: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: LinearGradient(colors: [accent.withOpacity(0.1), Colors.purple.withOpacity(0.05)])),
        child: Row(children: [const Text('💰', style: TextStyle(fontSize: 24)), const SizedBox(width: 12),
          Expanded(child: Text('Monthly Budget', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface))),
          Text(monthBud > 0 ? fmtInt(monthBud) : 'Not set', style: GoogleFonts.jetBrainsMono(fontSize: 16, fontWeight: FontWeight.w700, color: monthBud > 0 ? accent : cs.onSurface.withOpacity(0.3))),
          const SizedBox(width: 6), Icon(Icons.edit_rounded, size: 16, color: cs.onSurface.withOpacity(0.3))]))),
      const SizedBox(height: 8),
      Padding(padding: const EdgeInsets.fromLTRB(18, 4, 18, 8), child: Text('Category budgets (optional — tap to set)', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.35)))),
      ...cats.map((cat) { final bud = catB[cat.id] ?? 0; final spent = txns.where((t) => t.type == 'expense' && t.category == cat.id).fold(0.0, (s, t) => s + t.amount); final pct = bud > 0 ? (spent / bud).clamp(0.0, 1.0) : 0.0;
        return GestureDetector(onTap: () => onEditCat(cat.id), child: Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3), padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
          child: Column(children: [Row(children: [Text(cat.icon, style: const TextStyle(fontSize: 20)), const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(cat.name, style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
              Text(bud > 0 ? '${fmtAmt(spent)} / ${fmtInt(bud)}' : spent > 0 ? fmtAmt(spent) : 'No budget set', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.4)))])),
            bud > 0 ? Text(spent > bud ? 'Over!' : '${fmtAmt(bud - spent)} left', style: GoogleFonts.jetBrainsMono(fontSize: 11, fontWeight: FontWeight.w700, color: spent > bud ? const Color(0xFFF43F5E) : const Color(0xFF22C55E))) : Icon(Icons.add_rounded, size: 18, color: cs.onSurface.withOpacity(0.2))]),
            if (bud > 0) ...[const SizedBox(height: 8), ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: pct, minHeight: 5, backgroundColor: cs.outline.withOpacity(0.1), valueColor: AlwaysStoppedAnimation(pct > 0.9 ? const Color(0xFFF43F5E) : cat.color)))]]))); })]));
  }
}

// ═══ STATS ═══

class _StatsTab extends StatelessWidget {
  final List<Txn> txns; final Color accent; final double tExp, tInc; final Map<String, int> catB; final int monthBud;
  const _StatsTab({required this.txns, required this.accent, required this.tExp, required this.tInc, required this.catB, required this.monthBud});
  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme;
    final sr = tInc > 0 ? ((tInc - tExp) / tInc * 100).round() : 0;
    final now = DateTime.now(); final dim = DateUtils.getDaysInMonth(now.year, now.month);
    final dp = now.day; final dl = dim - dp;
    final da = dp > 0 && tExp > 0 ? tExp / dp : 0.0;
    final proj = da * dim;
    final ec = txns.where((t) => t.type == 'expense').length;
    final at = ec > 0 ? tExp / ec : 0.0;
    final pie = cats.map((c) => MapEntry(c, txns.where((t) => t.type == 'expense' && t.category == c.id).fold(0.0, (s, t) => s + t.amount))).where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    final dayAmt = <int, double>{};
    for (var t in txns.where((t) => t.type == 'expense' && t.date.month == now.month && t.date.year == now.year)) dayAmt[t.date.day] = (dayAmt[t.date.day] ?? 0) + t.amount;
    final maxDay = dayAmt.values.isEmpty ? 1.0 : dayAmt.values.reduce(math.max);
    final daily = List<double>.filled(dp, 0);
    for (var t in txns.where((t) => t.type == 'expense' && t.date.month == now.month && t.date.year == now.year)) if (t.date.day <= dp) daily[t.date.day - 1] += t.amount;
    final cum = <double>[]; double cumR = 0; for (var d in daily) { cumR += d; cum.add(cumR); }

    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 120), children: [
      Padding(padding: const EdgeInsets.fromLTRB(20, 18, 20, 14), child: Text('Analytics', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w800, color: cs.onSurface))),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [
        _sb('Savings', '$sr%', 'Income minus expenses,\ndivided by income', accent, cs),
        const SizedBox(width: 8),
        _sb('Daily Avg', fmtAmt(da), 'Total spent this month\ndivided by days passed', const Color(0xFFF97316), cs),
        const SizedBox(width: 8),
        _sb('Avg Txn', fmtAmt(at), 'Total spent divided by\nnumber of payments', const Color(0xFF8B5CF6), cs)])),
      Container(margin: const EdgeInsets.fromLTRB(16, 10, 16, 0), padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
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
          SizedBox(height: 90, child: CustomPaint(size: const Size(double.infinity, 90), painter: _TrendPainter(cum, accent)))])),
      if (pie.isNotEmpty) ...[
        Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 8), child: Text('BREAKDOWN', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.35), letterSpacing: 1))),
        Center(child: SizedBox(width: 160, height: 160, child: CustomPaint(painter: _PiePainter(pie, tExp, Theme.of(context).scaffoldBackgroundColor)))),
        const SizedBox(height: 12),
        ...pie.map((e) { final p = tExp > 0 ? (e.value / tExp * 100).round() : 0; final cb = catB[e.key.id] ?? 0;
          return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3), child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(borderRadius: BorderRadius.circular(3), color: e.key.color)),
            const SizedBox(width: 8), Text(e.key.icon), const SizedBox(width: 6),
            Expanded(child: Text(e.key.name, style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.6)))),
            cb > 0 ? Text('${fmtAmt(e.value)}/${fmtInt(cb)}', style: GoogleFonts.jetBrainsMono(fontSize: 10, color: e.value > cb ? const Color(0xFFF43F5E) : cs.onSurface.withOpacity(0.4)))
              : Text(fmtAmt(e.value), style: GoogleFonts.jetBrainsMono(fontSize: 10, fontWeight: FontWeight.w700, color: e.key.color)),
            const SizedBox(width: 8), SizedBox(width: 32, child: Text('$p%', style: GoogleFonts.jetBrainsMono(fontSize: 10, color: cs.onSurface.withOpacity(0.35)), textAlign: TextAlign.right))])); })],
      if (txns.isNotEmpty) Container(margin: const EdgeInsets.fromLTRB(16, 14, 16, 0), padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: accent.withOpacity(0.06)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Text('🧠', style: TextStyle(fontSize: 16)), const SizedBox(width: 8), Text('AI Overview', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent))]), const SizedBox(height: 8),
          Text(_ai(), style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.65), height: 1.5))])),
    ]));
  }

  Widget _sb(String l, String v, String tip, Color c, ColorScheme cs) => Expanded(child: Tooltip(message: tip, child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(l, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))), const SizedBox(height: 4), Text(v, style: GoogleFonts.jetBrainsMono(fontSize: 16, fontWeight: FontWeight.w800, color: c))]))));

  String _ai() {
    final dp = DateTime.now().day; final dl = DateUtils.getDaysInMonth(DateTime.now().year, DateTime.now().month) - dp;
    final da = dp > 0 && tExp > 0 ? tExp / dp : 0.0; final proj = da * DateUtils.getDaysInMonth(DateTime.now().year, DateTime.now().month);
    if (tExp == 0) return 'No expenses recorded yet. Add transactions to see spending insights.';
    final ec = txns.where((t) => t.type == 'expense').length;
    final p = <String>[];
    p.add('$ec expenses, avg ${fmtAmt(tExp / ec)} each.');
    if (monthBud > 0) p.add(proj > monthBud ? '⚠️ Projected ${fmtAmt(proj)} exceeds ${fmtInt(monthBud)} budget.' : '✅ On track: ${fmtAmt(proj)} projected of ${fmtInt(monthBud)}.');
    if (tInc > 0) p.add('Savings: ${((tInc - tExp) / tInc * 100).round()}%.');
    if (dl > 0 && monthBud > 0 && monthBud > tExp) p.add('${fmtAmt((monthBud - tExp) / dl)}/day for remaining $dl days.');
    return p.join('\n');
  }
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
  Future<void> _lp() async { final p = await SharedPreferences.getInstance(); setState(() { _bio = p.getBool('biometric') ?? false; _name = p.getString('user_name') ?? ''; }); }
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
      _tog('Fingerprint Lock', Icons.fingerprint_rounded, _bio, (v) async { HapticFeedback.lightImpact(); final p = await SharedPreferences.getInstance(); p.setBool('biometric', v); setState(() => _bio = v); }, cs),
      _row('Notification Access', Icons.notifications_rounded, widget.notifOk ? 'Enabled' : 'Disabled', widget.onNotif, cs, sc: widget.notifOk ? const Color(0xFF34D399) : const Color(0xFFEF4444)),
      // ── APPEARANCE ──
      _sec('APPEARANCE', Icons.palette_rounded, cs),
      _row('Theme', widget.isDark ? Icons.dark_mode_rounded : Icons.wb_sunny_rounded, widget.isDark ? 'Dark' : 'Light', widget.tTheme, cs),
      Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(16), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Accent Color', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)), const SizedBox(height: 14),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: List.generate(8, (i) { final c = accents[i]; return GestureDetector(onTap: () { HapticFeedback.lightImpact(); widget.sAccent(i); }, child: Container(width: 36, height: 36, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(12), border: Border.all(color: c.value == widget.accent.value ? cs.onSurface : Colors.transparent, width: 2.5)), child: c.value == widget.accent.value ? const Icon(Icons.check, color: Colors.white, size: 16) : null)); }))])),
      Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(16), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Display Size', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: cs.onSurface)),
          Text(_scaleNames[widget.scaleIdx], style: TextStyle(fontSize: 13, color: widget.accent, fontWeight: FontWeight.w600)),
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
  @override Widget build(BuildContext context) { final cs = Theme.of(context).colorScheme; final cl = _exp ? cats : iCats; final ok = _amt.isNotEmpty && _merch.isNotEmpty && _cat.isNotEmpty;
    return Container(constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88), decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 34), children: [
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))), const SizedBox(height: 16),
        Text('Add Transaction', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: cs.onSurface)), const SizedBox(height: 14),
        Row(children: [
          Expanded(child: GestureDetector(onTap: () => setState(() { _exp = true; _cat = ''; }), child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: _exp ? const Color(0xFFF43F5E).withOpacity(0.1) : Colors.transparent, border: Border.all(color: _exp ? const Color(0xFFF43F5E).withOpacity(0.3) : cs.outline.withOpacity(0.1))), child: Center(child: Text('💸 Expense', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _exp ? const Color(0xFFF43F5E) : cs.onSurface.withOpacity(0.4))))))),
          const SizedBox(width: 8),
          Expanded(child: GestureDetector(onTap: () => setState(() { _exp = false; _cat = ''; }), child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: !_exp ? const Color(0xFF22C55E).withOpacity(0.1) : Colors.transparent, border: Border.all(color: !_exp ? const Color(0xFF22C55E).withOpacity(0.3) : cs.outline.withOpacity(0.1))), child: Center(child: Text('💰 Income', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: !_exp ? const Color(0xFF22C55E) : cs.onSurface.withOpacity(0.4))))))),
        ]), const SizedBox(height: 14),
        TextField(keyboardType: const TextInputType.numberWithOptions(decimal: true), onChanged: (v) => setState(() => _amt = v), style: GoogleFonts.jetBrainsMono(fontSize: 28, fontWeight: FontWeight.w800),
          decoration: InputDecoration(hintText: '₹ 0', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 10),
        TextField(onChanged: (v) => setState(() => _merch = v), decoration: InputDecoration(hintText: _exp ? 'Merchant' : 'Source', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 10),
        TextField(onChanged: (v) => _note = v, decoration: InputDecoration(hintText: 'Note (optional)', prefixIcon: Icon(Icons.edit_note_rounded, color: cs.onSurface.withOpacity(0.3)), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 14),
        GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 7, crossAxisSpacing: 7, childAspectRatio: 1.15), itemCount: cl.length,
          itemBuilder: (_, i) { final c = cl[i]; final sel = _cat == c.id;
            return GestureDetector(onTap: () => setState(() => _cat = c.id), child: Container(decoration: BoxDecoration(color: sel ? c.color.withOpacity(0.15) : cs.outline.withOpacity(0.04), borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? c.color.withOpacity(0.4) : cs.outline.withOpacity(0.08))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(c.icon, style: const TextStyle(fontSize: 20)), const SizedBox(height: 3), Text(c.name, style: TextStyle(fontSize: 9, color: sel ? c.color : cs.onSurface.withOpacity(0.5), fontWeight: sel ? FontWeight.w700 : FontWeight.w400), textAlign: TextAlign.center, maxLines: 2)]))); }),
        const SizedBox(height: 18),
        ElevatedButton(onPressed: ok ? () {
          final amount = double.tryParse(_amt.replaceAll(',','').replaceAll(' ','')) ?? 0;
          if (amount <= 0) return;
          widget.onAdd(Txn(id: DateTime.now().millisecondsSinceEpoch.toString(), amount: amount, merchant: _merch, category: _cat, account: 'gpay', type: _exp ? 'expense' : 'income', date: DateTime.now(), note: _note));
        } : null,
          style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.all(16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          child: Text('Add ${_exp ? "Expense" : "Income"}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)))]));
  }
}

class _EditSheet extends StatefulWidget {
  final Txn txn; final Color accent; final ValueChanged<Txn> onSave; final VoidCallback onDelete, onStopAuto;
  const _EditSheet({required this.txn, required this.accent, required this.onSave, required this.onDelete, required this.onStopAuto});
  @override State<_EditSheet> createState() => _EditSheetState();
}
class _EditSheetState extends State<_EditSheet> {
  late String _cat, _note; late TextEditingController _nc;
  @override void initState() { super.initState(); _cat = widget.txn.category; _note = widget.txn.note; _nc = TextEditingController(text: _note); }
  @override Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme; final isI = widget.txn.type == 'income'; final cl = isI ? iCats : cats;
    return Container(constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.78), decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 34), children: [
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))), const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Edit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: cs.onSurface)),
          Row(children: [TextButton(onPressed: () { HapticFeedback.lightImpact(); widget.onStopAuto(); }, child: Text('Stop Auto', style: TextStyle(color: cs.onSurface.withOpacity(0.4), fontSize: 12))),
            TextButton(onPressed: () { HapticFeedback.mediumImpact(); widget.onDelete(); }, child: const Text('Delete', style: TextStyle(color: Color(0xFFEF4444), fontWeight: FontWeight.w700, fontSize: 12)))])]),
        const SizedBox(height: 8),
        Text(isI ? '+${fmtAmt(widget.txn.amount)}' : '-${fmtAmt(widget.txn.amount)}', style: GoogleFonts.jetBrainsMono(fontSize: 26, fontWeight: FontWeight.w800, color: isI ? const Color(0xFF22C55E) : cs.onSurface)),
        Text('${widget.txn.merchant} · ${DateFormat('MMM d, h:mm a').format(widget.txn.date)}', style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.5))),
        const SizedBox(height: 12),
        TextField(controller: _nc, onChanged: (v) => _note = v, decoration: InputDecoration(hintText: 'Note', prefixIcon: Icon(Icons.edit_note_rounded, color: cs.onSurface.withOpacity(0.3)), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 12),
        GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 7, crossAxisSpacing: 7, childAspectRatio: 1.15), itemCount: cl.length,
          itemBuilder: (_, i) { final c = cl[i]; final sel = _cat == c.id;
            return GestureDetector(onTap: () => setState(() => _cat = c.id), child: Container(decoration: BoxDecoration(color: sel ? c.color.withOpacity(0.15) : cs.outline.withOpacity(0.04), borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? c.color.withOpacity(0.4) : cs.outline.withOpacity(0.08))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(c.icon, style: const TextStyle(fontSize: 20)), const SizedBox(height: 3), Text(c.name, style: TextStyle(fontSize: 9, color: sel ? c.color : cs.onSurface.withOpacity(0.5), fontWeight: sel ? FontWeight.w700 : FontWeight.w400), textAlign: TextAlign.center, maxLines: 2)]))); }),
        const SizedBox(height: 16),
        ElevatedButton(onPressed: () => widget.onSave(Txn(id: widget.txn.id, amount: widget.txn.amount, merchant: widget.txn.merchant, category: _cat, account: widget.txn.account, type: widget.txn.type, date: widget.txn.date, note: _note)),
          style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.all(16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          child: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15)))]));
  }
}