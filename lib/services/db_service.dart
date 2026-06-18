import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

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