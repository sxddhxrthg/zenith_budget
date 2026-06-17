class Txn {
  String id; double amount; String merchant, category, account, type, note; DateTime date;
  Txn({required this.id, required this.amount, required this.merchant, required this.category, required this.account, required this.type, required this.date, this.note = ''});
  Map<String, dynamic> toMap() => {'id': id, 'amount': amount, 'merchant': merchant, 'category': category, 'account': account, 'type': type, 'date': date.toIso8601String(), 'note': note};
  factory Txn.fromMap(Map<String, dynamic> m) => Txn(id: m['id'], amount: (m['amount'] as num).toDouble(), merchant: m['merchant'] ?? '', category: m['category'] ?? 'other', account: m['account'] ?? 'gpay', type: m['type'] ?? 'expense', date: DateTime.tryParse(m['date'] ?? '') ?? DateTime.now(), note: m['note'] ?? '');
}
