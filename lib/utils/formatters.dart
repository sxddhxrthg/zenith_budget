import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';

String fmtAmt(double n) => NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2).format(n);
String fmtInt(int n) => NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0).format(n);

class TimePref {
  static bool use24h = false;

  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    use24h = p.getBool('time_format_24h') ?? false;
  }

  static Future<void> set(bool v) async {
    use24h = v;
    final p = await SharedPreferences.getInstance();
    await p.setBool('time_format_24h', v);
  }
}

String fmtTxnTime(DateTime d) =>
    DateFormat(TimePref.use24h ? 'HH:mm' : 'h:mm a').format(d);