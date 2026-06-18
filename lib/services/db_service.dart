import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

// ═══════════════════════════════════════
// DATABASE — amounts stored as-is, no rounding tricks
// Total monthly budget in SharedPreferences (single int, never split)
// Category budgets in SQLite ONLY if user explicitly sets them
//
// Merchant normalization:
//   • merchantKey(s)     → lowercase, trimmed, whitespace-collapsed.
//                          Used as the primary key into merchant_map and
//                          for any cross-row grouping in the UI.
//   • merchantDisplay(s) → title-cased canonical form. Applied on every
//                          txn write so the Activity feed, Top Merchants,
//                          and Edit sheet all show the same casing.
//
// Schema preserved (zenith_v7.db, version 1). No migration needed:
// old rows keep their original case in txns.merchant — new writes (and
// re-saves via the Edit sheet) gradually canonicalize them.
// ═══════════════════════════════════════

class Db {
  static Database? _db;

  // ─── Merchant normalization helpers ───────────────────────────────────────

  static String merchantKey(String m) =>
      m.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  static String merchantDisplay(String m) {
    final t = m.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (t.isEmpty) return t;
    return t
        .split(' ')
        .map((w) => w.isEmpty
            ? w
            : w[0].toUpperCase() +
                (w.length > 1 ? w.substring(1).toLowerCase() : ''))
        .join(' ');
  }

  // ─── Connection ───────────────────────────────────────────────────────────

  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await openDatabase(
      p.join(await getDatabasesPath(), 'zenith_v7.db'),
      version: 1,
      onCreate: (db, v) async {
        await db.execute(
            'CREATE TABLE txns(id TEXT PRIMARY KEY, amount REAL, merchant TEXT, category TEXT, account TEXT, type TEXT, date TEXT, note TEXT)');
        await db.execute(
            'CREATE TABLE merchant_map(merchant TEXT PRIMARY KEY, category TEXT, auto_enabled INTEGER DEFAULT 1)');
        await db.execute(
            'CREATE TABLE cat_budgets(category TEXT PRIMARY KEY, budget INTEGER)');
      },
    );
    return _db!;
  }

  // ─── Transactions ─────────────────────────────────────────────────────────

  static Future<void> insTxn(Map<String, dynamic> t) async {
    final m = Map<String, dynamic>.from(t);
    m['merchant'] = merchantDisplay((m['merchant'] as String?) ?? '');
    await (await db)
        .insert('txns', m, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> updTxn(Map<String, dynamic> t) async {
    final m = Map<String, dynamic>.from(t);
    m['merchant'] = merchantDisplay((m['merchant'] as String?) ?? '');
    await (await db).update('txns', m, where: 'id=?', whereArgs: [m['id']]);
  }

  static Future<void> delTxn(String id) async =>
      (await db).delete('txns', where: 'id=?', whereArgs: [id]);

  static Future<List<Map<String, dynamic>>> allTxns() async =>
      (await db).query('txns', orderBy: 'date DESC');

  // ─── Merchant memory ──────────────────────────────────────────────────────

  // Returns the learned category iff auto-learning is enabled. Returns null
  // when the merchant has never been learned OR when learning was explicitly
  // stopped for it.
  static Future<String?> getAutoCat(String m) async {
    final k = merchantKey(m);
    if (k.isEmpty) return null;
    final r = await (await db).query('merchant_map',
        where: 'merchant=? AND auto_enabled=1', whereArgs: [k]);
    return r.isNotEmpty ? r.first['category'] as String? : null;
  }

  // Hard-write: forces a learned mapping with auto_enabled=1.
  // Used by the notification opt-in flow where the user explicitly ticks the
  // "auto-categorize this merchant" toggle in the categorization sheet.
  static Future<void> setAutoCat(String m, String c) async {
    final k = merchantKey(m);
    if (k.isEmpty) return;
    await (await db).insert(
      'merchant_map',
      {'merchant': k, 'category': c, 'auto_enabled': 1},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // Soft-write from a manual add/edit. Respects prior stop-learning: if the
  // user previously turned learning off for this merchant, we never resurrect
  // it. Otherwise we either insert a new row or update the learned category.
  static Future<void> learnMerchant(String m, String c) async {
    final k = merchantKey(m);
    if (k.isEmpty || c.isEmpty) return;
    final database = await db;
    final r = await database
        .query('merchant_map', where: 'merchant=?', whereArgs: [k]);
    if (r.isEmpty) {
      await database.insert('merchant_map',
          {'merchant': k, 'category': c, 'auto_enabled': 1});
    } else if ((r.first['auto_enabled'] as int? ?? 0) == 1) {
      await database.update('merchant_map', {'category': c},
          where: 'merchant=?', whereArgs: [k]);
    }
    // else: auto_enabled == 0 → user previously stopped learning. Leave alone.
  }

  // Durable stop. Upserts an auto_enabled=0 row so the stop persists even for
  // merchants that were never auto-learned through the notification path.
  static Future<void> stopAuto(String m) async {
    final k = merchantKey(m);
    if (k.isEmpty) return;
    final database = await db;
    final r = await database
        .query('merchant_map', where: 'merchant=?', whereArgs: [k]);
    if (r.isEmpty) {
      await database.insert('merchant_map',
          {'merchant': k, 'category': '', 'auto_enabled': 0});
    } else {
      await database.update('merchant_map', {'auto_enabled': 0},
          where: 'merchant=?', whereArgs: [k]);
    }
  }

  // ─── Category budgets ─────────────────────────────────────────────────────

  static Future<void> setCatBudget(String cat, int amt) async =>
      (await db).insert('cat_budgets', {'category': cat, 'budget': amt},
          conflictAlgorithm: ConflictAlgorithm.replace);

  static Future<void> delCatBudget(String cat) async =>
      (await db).delete('cat_budgets', where: 'category=?', whereArgs: [cat]);

  static Future<Map<String, int>> catBudgets() async {
    final r = await (await db).query('cat_budgets');
    return {
      for (var row in r) row['category'] as String: (row['budget'] as num).toInt()
    };
  }
}
