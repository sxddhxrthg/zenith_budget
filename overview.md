# ZENITH BUDGET TRACKER — Project Handoff

## Project Context

I'm building a Flutter budget tracker for the Android Play Store. The app auto-detects GPay/UPI payments via Android's NotificationListenerService. I'm working toward launching on the Play Store because it could help me land a job.

- **Developer:** Siddharth (me)
- **Environment:** MacBook Air M3, Nothing Phone 2 (Android 16/API 36)
- **Project root:** `~/Desktop/zenith_budget`
- **Package name:** `com.zenith.zenith_budget`
- **Tech stack:** Flutter + Dart + Kotlin (native), SQLite, Firebase (bypassed for now)

---

## Architecture Overview

### File Structure
```
~/Desktop/zenith_budget/
├── lib/
│   ├── main.dart                    # Main app — all UI, DB, business logic
│   └── auth_bypass.dart             # Welcome screen + biometric gate (bypasses Google Sign-In)
├── pubspec.yaml                     # Dependencies + assets + icon/splash config
├── assets/
│   └── icon.png                     # Z logo (red gradient Z with arrow)
└── android/
    ├── app/
    │   ├── google-services.json     # Firebase config (currently unused)
    │   ├── build.gradle.kts
    │   └── src/main/
    │       ├── AndroidManifest.xml
    │       └── kotlin/com/zenith/zenith_budget/
    │           ├── MainActivity.kt                         # FlutterFragmentActivity, method/event channels
    │           ├── TransactionNotificationListener.kt      # Listens to payment app notifications
    │           └── TransactionParser.kt                    # Regex-based amount/merchant extraction
    └── settings.gradle.kts
```

### Native Bridge (Kotlin ↔ Flutter)
- **Method channel:** `com.zenith.budget/methods` — for checking/requesting notification access
- **Event channel:** `com.zenith.budget/transactions` — streams parsed transactions to Flutter
- **Notification dedup:** 10-second window in Kotlin to prevent duplicate transactions
- **Biometric fix:** No lifecycle observer (prevents infinite loop)

### Database
SQLite database `zenith_v8.db` in app documents directory with tables:
- `txns` — transactions (id, amount, merchant, category, subcategory, account, type, date, note, trip_id)
- `merchant_map` — auto-categorization rules (merchant → category, auto_enabled flag)
- `cat_budgets` — per-category budgets (category → budget amount)
- `custom_cats` — user-created categories (id, name, icon, color, parent for subcategories)
- `trips` — trip budgets (id, name, budget, start_date, end_date)

Monthly budget is stored separately in `SharedPreferences` as int key `monthly_budget`.

---

## Current Feature Set (Working)

### Core
- Welcome screen with name entry + biometric lock toggle
- App logo (Z gradient) as launcher icon and on welcome screen
- Splash screen with dark background and logo
- SQLite persistence across app restarts
- Dark/light mode toggle
- 8 accent colors
- Auto-detection of payments from GPay, PhonePe, Paytm, BHIM, iMobile, YONO SBI, HDFC, Axis Mobile
- SMS filter that only processes bank/payment SMS (ignores WhatsApp, Instagram, etc.)
- Expense vs income auto-detection from notification text
- Auto-categorize repeat merchants (after first categorization)

### Tabs
- **Home** — Monthly budget ring, balance card, spending heatmap (calendar view with intensity), cumulative trend chart with day labels, category pie chart, recent transactions grouped by date
- **Activity** — All transactions, tap to edit/delete
- **Budgets** — Monthly total budget, per-category budgets, custom categories with emoji+color picker, subcategories, trip budgets with date ranges
- **Stats** — Savings rate, daily average, projected monthly spend, category breakdown pie chart
- **Settings** — Fingerprint toggle, notification access, theme toggle, accent color picker, separate font size slider, separate UI size slider, monitored apps toggles (8 payment apps)

### Formatting
- Amounts show 2 decimal places (₹1,234.56) via `fmtAmt()`
- Integer budgets via `fmtInt()`
- Indian locale (en_IN)

---

## Recent Changes (Last Session)

1. Fixed ₹10,000 → ₹9,900 rounding bug — monthly budget was being split across 15 categories. Now stored as single int in SharedPreferences.
2. Fixed `intl` TextDirection conflict — `import 'package:intl/intl.dart' hide TextDirection;`
3. Added app icon (Z logo at `assets/icon.png`) — launcher icon works on home screen
4. Fixed welcome screen to show logo image instead of text "Z"
5. Added splash screen config with `flutter_native_splash`
6. Added custom categories with emoji + color picker
7. Added subcategories (tap "+ sub" under any category)
8. Added trip budgets with date range picker, dismissible to delete
9. Added trip dropdown in Add Transaction sheet
10. Separated font scale from UI scale — two independent sliders in Settings
11. Added monitored apps section in Settings with toggles for each payment app

---

## TODO / Remaining Work

### High Priority
1. **Test the v2 build on the phone** — Files are at `~/Desktop/zenith_budget/lib/main.dart` and `pubspec.yaml`. Run:
   ```
   cd ~/Desktop/zenith_budget
   flutter pub get
   dart run flutter_native_splash:create
   flutter run
   ```
   Verify custom categories, subcategories, trip budgets, font/UI sliders, and monitored apps toggles all work.

2. **Make monitored apps toggles actually do something** — The toggles save to SharedPreferences (`app_{packageName}` bool keys) but the Kotlin `TransactionNotificationListener.kt` doesn't read them yet. Need to update Kotlin to check these prefs and skip disabled apps. File: `android/app/src/main/kotlin/com/zenith/zenith_budget/TransactionNotificationListener.kt`

3. **Fingerprint re-lock when returning from background** — Currently biometric only fires on cold start. Should re-lock when app is backgrounded > 1 min. Add `WidgetsBindingObserver` in `auth_bypass.dart`.

### Medium Priority
4. **Export to CSV** — Add button in Settings to export all transactions to CSV file
5. **Recurring transaction detection** — Flag monthly subscriptions, rent, etc. that repeat on similar dates
6. **Font style options** — Currently only size is adjustable. Add font family picker (e.g., Outfit, Inter, Roboto, system default)
7. **APK build for friends** — `flutter build apk --release` produces `build/app/outputs/flutter-apk/app-release.apk`. Need to test signed release build.

### Low Priority (Blocked)
8. **Google Sign-In** — Currently bypassed due to `ApiException:10` (SHA-1 config issue). Firebase project "Zenith Budget" exists on Spark/free plan with SHA-1 `2F:AA:39:89:45:BB:89:83:C0:19:F0:96:96:4B:02:53:B2:AE:8D:B5` registered. Cloud Firestore is enabled in asia-south1 test mode. Not critical — app works fully offline.
9. **Cloud backup/restore across devices** — Blocked by Google Sign-In
10. **Play Store listing** — $25 account fee, needs 20 testers for 14-day closed test, 3-7 day review, ~6-10 weeks total. Needs screenshots, icon (512×512), feature graphic, privacy policy.

---

## Known Quirks

- The current `main.dart` is ~900 lines, heavily compacted (single-line widget trees). It's dense but functional. Don't reformat unless specifically asked.
- The project uses `FlutterFragmentActivity` (not `FlutterActivity`) to support biometric auth.
- Desugaring is enabled in `build.gradle.kts` for Java 11 compatibility.
- `minSdk` is 26, `targetSdk` follows Flutter defaults.
- Firebase packages are in `pubspec.yaml` but only `firebase_core` is actually initialized. Sign-in/Firestore code paths are unused.

---

## Dependencies (pubspec.yaml)

```yaml
dependencies:
  flutter: sdk
  cupertino_icons: ^1.0.8
  google_fonts: ^6.2.1       # Outfit + JetBrainsMono fonts
  sqflite: ^2.4.1            # Local database
  path: ^1.9.0
  provider: ^6.1.2
  shared_preferences: ^2.3.4 # Prefs storage
  flutter_local_notifications: ^18.0.1
  intl: ^0.19.0              # Formatting, imported with `hide TextDirection`
  permission_handler: ^11.3.1
  local_auth: ^2.3.0         # Biometric
  firebase_core: ^3.8.1
  firebase_auth: ^5.3.4      # Unused
  google_sign_in: ^6.2.2     # Unused
  cloud_firestore: ^5.6.0    # Unused

dev_dependencies:
  flutter_launcher_icons: ^0.14.3
  flutter_native_splash: ^2.4.4
```

---

## Build & Run Commands

```bash
# Development
cd ~/Desktop/zenith_budget
flutter pub get
flutter run                                    # Runs on connected Nothing Phone 2

# After changing pubspec.yaml / assets
dart run flutter_launcher_icons                # Regenerate launcher icons
dart run flutter_native_splash:create          # Regenerate splash screen

# Release build
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

---

## What I'd Like Cowork To Help With

Start by asking me what I want to tackle first from the TODO list. My priorities in rough order:

1. Finish testing the v2 features on my phone and fix anything broken
2. Wire up the monitored apps toggles in Kotlin so they actually filter
3. Add fingerprint re-lock on background return
4. Polish the UI where needed
5. Build a signed APK I can share with friends
6. Eventually prep for Play Store submission

Please read through `~/Desktop/zenith_budget/lib/main.dart` and `~/Desktop/zenith_budget/lib/auth_bypass.dart` first to understand the current code structure before making changes. The code style is compact — keep it that way.

When making changes, show me the diff or the specific file section you're changing, not the entire rewritten file. I'll apply the edits myself.
