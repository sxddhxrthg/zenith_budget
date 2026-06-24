// Single source of truth for SharedPreferences keys.
// Scattered string literals risk silent corruption on typo and make
// grep-for-usage unreliable. Every read/write through SharedPreferences
// should reference one of these constants.
//
// On-disk key names are PRESERVED EXACTLY — these constants document what's
// already on every user's device. Changing any value here is a silent
// migration; do not.
//
// Note: settings_service.dart (TimePref, monthly budget helpers) also
// writes to SharedPreferences under its own literals. Aligning those is
// out of scope for P3.1.A — the constants here intentionally cover only
// the keys main.dart currently reads/writes directly.
class PrefsKeys {
  PrefsKeys._();

  // Theme & appearance
  static const String theme = 'theme';                  // 'light' | 'dark'
  static const String accent = 'accent';                // int index into accents[]
  static const String fontScale = 'font_scale';         // int index into scales[]
  static const String time24h = 'time_format_24h';      // bool

  // Account & security
  static const String userName = 'user_name';           // String
  static const String biometric = 'biometric';          // bool

  // Subscriptions (P2.7)
  static const String subscriptions = 'subscriptions';                   // JSON list
  static const String declinedSubMerchants = 'declined_sub_merchants';   // List<String>
  static const String subPaidOverride = 'sub_paid_override';             // JSON map
}