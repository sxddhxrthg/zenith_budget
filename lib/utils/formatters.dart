import 'package:intl/intl.dart' hide TextDirection;

String fmtAmt(double n) => NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2).format(n);
String fmtInt(int n) => NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0).format(n);
