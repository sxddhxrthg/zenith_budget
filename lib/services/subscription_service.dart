// P3.1.C — Pure subscription business helpers extracted verbatim from main.dart.
// No behavior changes. These functions:
//   • depend only on already-loaded data passed in by callers
//   • have no BuildContext, no State, no setState, no SharedPreferences, no DB writes
//   • are read-only intelligence over transactions and categories
//
// Companion to subscription_rules.dart (P3.1.B): rules.dart owns cycle/window
// math; service.dart owns the higher-level subscription business rules
// (category resolution, entry-time confidence heuristics). Same purity contract.
//
// `cats` is typed Iterable<dynamic> so this file is decoupled from the exact
// category-model type used in main.dart. Member access (.name, .id) resolves
// at runtime identically to the original inline call site, which carried no
// explicit type either. If a future phase introduces a public Category type,
// tighten this signature then — not before.
import '../models/transaction.dart';
import 'db_service.dart';

// P2.7.9 — id of the "Subscriptions" expense category. Resolved against the
// passed-in category list so a rename anywhere in the category model can't
// desync this. Returns '' if the category was removed; callers must handle that.
String subsCatId(Iterable<dynamic> cats) {
  try {
    return cats.firstWhere((c) => (c.name as String).toLowerCase() == 'subscriptions').id as String;
  } catch (_) {
    return '';
  }
}

// P2.7.5.1 — heuristic confidence for entry-time subscription suggestions
// (no DB, history-based):
//   low  (food delivery / rides / marketplaces / eateries) → never ask here; P2.7.2 handles it.
//   high (clear subscription brands)                        → ask on the first charge.
//   medium (anything else)                                  → ask only once a second charge
//                                                              of a near-equal amount is seen.
// Deliberately conservative: missing a few subscriptions beats nagging the user.
bool entryConfident(Txn t, String key, List<Txn> txns) {
  const low = ['swiggy', 'zomato', 'uber', 'ola', 'rapido', 'amazon', 'flipkart', 'pizza', 'domino', 'kfc', 'mcdonald', 'burger', 'blinkit', 'zepto', 'instamart', 'bigbasket', 'dunzo', 'myntra', 'meesho', 'ajio', 'starbucks', 'cafe', 'restaurant', 'petrol', 'fuel'];
  const high = ['netflix', 'spotify', 'google one', 'youtube premium', 'youtube music', 'apple music', 'apple tv', 'icloud', 'chatgpt', 'openai', 'hotstar', 'audible', 'gym'];
  if (low.any((k) => key.contains(k))) return false;
  if (high.any((k) => key.contains(k))) return true;
  final tol = (t.amount * 0.15).clamp(1.0, double.infinity);
  return txns.any((x) => x.type == 'expense' && x.id != t.id && Db.merchantKey(x.merchant) == key && (x.amount - t.amount).abs() <= tol);
}