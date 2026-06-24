// P3.1.A — Typed in-memory model for a subscription. The on-disk JSON shape
// is PRESERVED EXACTLY — every key, every type, every nullable. fromJson
// reads what _ShellState.persistSubs writes today; toJson reproduces that
// shape byte-for-byte. No migration. No conversion at rest.
//
// Identity = key (Db.merchantKey) + cadence + schedule. amount is mutable
// (price changes update in place); identity NEVER includes amount.
//
// Not wired into main.dart yet — file exists so the JSON contract is
// captured in one place and subscription_service (P3.1.C) can adopt it
// without re-deriving the shape from inline access patterns.
class Subscription {
  final String key;             // Db.merchantKey(merchant)
  final String name;            // display name (Db.merchantDisplay)
  final double amount;          // current charge; mutable across price changes
  final String cadence;         // 'weekly' | 'monthly'
  final int? day;               // weekly: 1..7 (Mon..Sun); monthly: 1..31
  final String? time;           // 'HH:MM' 24h; null = no schedule recorded
  final String source;          // 'auto' (detection-approved) | 'manual'
  final double? previousAmount; // P2.7.9 — set when amount changed
  final String? priceChangedAt; // P2.7.9 — ISO-8601 timestamp of the change

  const Subscription({
    required this.key,
    required this.name,
    required this.amount,
    required this.cadence,
    required this.source,
    this.day,
    this.time,
    this.previousAmount,
    this.priceChangedAt,
  });

  // Mirror of the Map<String, dynamic> shape persisted today. Tolerant to
  // the historical num/double/int interplay (amount has been stored as
  // both int and double through the lifetime of P2.7).
  factory Subscription.fromJson(Map<String, dynamic> m) => Subscription(
        key: (m['key'] as String?) ?? '',
        name: (m['name'] as String?) ?? '',
        amount: ((m['amount'] as num?) ?? 0).toDouble(),
        cadence: (m['cadence'] as String?) ?? 'monthly',
        day: (m['day'] as num?)?.toInt(),
        time: m['time'] as String?,
        source: (m['source'] as String?) ?? 'manual',
        previousAmount: (m['previousAmount'] as num?)?.toDouble(),
        priceChangedAt: m['priceChangedAt'] as String?,
      );

  // Round-trip contract: writes ONLY the keys the existing on-disk shape
  // has, and only when non-null — matching today's behavior in _upsertSub,
  // which conditionally copies previousAmount / priceChangedAt forward and
  // never writes nulls into the map. Required-field keys are always emitted.
  Map<String, dynamic> toJson() {
    final m = <String, dynamic>{
      'key': key,
      'name': name,
      'amount': amount,
      'cadence': cadence,
      'source': source,
    };
    if (day != null) m['day'] = day;
    if (time != null) m['time'] = time;
    if (previousAmount != null) m['previousAmount'] = previousAmount;
    if (priceChangedAt != null) m['priceChangedAt'] = priceChangedAt;
    return m;
  }

  // Standard `?? this.x` copyWith. Cannot clear a nullable field to null;
  // that's not needed today (no call site clears these), and adding sentinel
  // params would be premature. Revisit when subscription_service needs it.
  Subscription copyWith({
    String? key,
    String? name,
    double? amount,
    String? cadence,
    int? day,
    String? time,
    String? source,
    double? previousAmount,
    String? priceChangedAt,
  }) =>
      Subscription(
        key: key ?? this.key,
        name: name ?? this.name,
        amount: amount ?? this.amount,
        cadence: cadence ?? this.cadence,
        day: day ?? this.day,
        time: time ?? this.time,
        source: source ?? this.source,
        previousAmount: previousAmount ?? this.previousAmount,
        priceChangedAt: priceChangedAt ?? this.priceChangedAt,
      );
}