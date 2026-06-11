# Zenith — Smart Budget Tracker

A Flutter-based budget tracker for Android that **auto-detects GPay & UPI payments** via Android's `NotificationListenerService`. No manual entry needed — just pay and it's tracked.

## Features

- **Auto-detection** — Listens to notifications from GPay, PhonePe, Paytm, BHIM UPI, iMobile Pay, YONO SBI, HDFC Bank, and Axis Mobile
- **Smart categorization** — Learns your spending patterns and auto-categorizes repeat merchants
- **Monthly budgets** — Set an overall budget and per-category limits with visual progress tracking
- **Trip budgets** — Plan travel spending with date ranges and assign expenses to trips
- **Custom categories** — Create your own with emoji and color pickers, plus subcategories
- **Spending heatmap** — Calendar view showing daily spending intensity
- **Trend chart** — Cumulative spending visualized across the month
- **Analytics** — Savings rate, daily average, projected monthly spend, category pie chart
- **Biometric lock** — Fingerprint authentication to keep your data private
- **Dark & light mode** — 8 accent colors, adjustable font size and UI scale

## Tech Stack

- **Flutter & Dart** — Cross-platform UI
- **Kotlin** — Native Android notification listener + transaction parser
- **SQLite** — Local-first database, no cloud dependency
- **SharedPreferences** — Settings persistence
- **Material 3** — Modern Android design language

## Architecture

```
lib/
├── main.dart              # App UI, database, business logic
└── auth_bypass.dart       # Welcome screen + biometric gate

android/.../kotlin/
├── MainActivity.kt                      # Flutter ↔ Kotlin bridge
├── TransactionNotificationListener.kt   # Notification capture
└── TransactionParser.kt                 # Regex-based amount/merchant extraction
```

The native Kotlin layer captures payment notifications, parses amounts and merchant names using regex, deduplicates within a 10-second window, and streams transactions to Flutter via an EventChannel.

## Getting Started

### Prerequisites
- Flutter SDK 3.5+
- Android Studio / VS Code
- Android device with notification access

### Run
```bash
git clone https://github.com/sxddhxrthg/zenith-budget.git
cd zenith-budget
flutter pub get
flutter run
```

### Build APK
```bash
flutter build apk --release
```

## Screenshots

*Coming soon*

## License

This project is open source under the [MIT License](LICENSE).
