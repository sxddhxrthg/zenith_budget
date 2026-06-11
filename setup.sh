#!/bin/bash
# ============================================================================
# ZENITH BUDGET TRACKER — Complete Production Setup Script
# Run: cd ~/Desktop/zenith_budget && bash setup.sh
# ============================================================================

set -e
echo "🚀 Starting Zenith complete rebuild..."

# ── pubspec.yaml ──
cat > pubspec.yaml << 'PUBSPEC'
name: zenith_budget
description: "Zenith - Smart Budget Tracker with GPay auto-detection"
publish_to: 'none'
version: 1.0.0+1

environment:
  sdk: ^3.5.0

dependencies:
  flutter:
    sdk: flutter
  cupertino_icons: ^1.0.8
  google_fonts: ^6.2.1
  sqflite: ^2.4.1
  path: ^1.9.0
  provider: ^6.1.2
  shared_preferences: ^2.3.4
  flutter_local_notifications: ^18.0.1
  intl: ^0.19.0
  permission_handler: ^11.3.1
  local_auth: ^2.3.0
  firebase_core: ^3.8.1
  firebase_auth: ^5.3.4
  google_sign_in: ^6.2.2
  cloud_firestore: ^5.6.0

dev_dependencies:
  flutter_test:
    sdk: flutter
  flutter_lints: ^5.0.0

flutter:
  uses-material-design: true
PUBSPEC

echo "✅ pubspec.yaml"

# ── Android Manifest ──
cat > android/app/src/main/AndroidManifest.xml << 'MANIFEST'
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.zenith.zenith_budget">

    <uses-permission android:name="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE" />
    <uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
    <uses-permission android:name="android.permission.SYSTEM_ALERT_WINDOW" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.INTERNET" />
    <uses-permission android:name="android.permission.USE_BIOMETRIC" />
    <uses-permission android:name="android.permission.USE_FINGERPRINT" />

    <application
        android:label="Zenith"
        android:name="${applicationName}"
        android:icon="@mipmap/ic_launcher"
        android:enableOnBackInvokedCallback="true">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:taskAffinity=""
            android:theme="@style/LaunchTheme"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:hardwareAccelerated="true"
            android:windowSoftInputMode="adjustResize">
            <meta-data android:name="io.flutter.embedding.android.NormalTheme" android:resource="@style/NormalTheme" />
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <service
            android:name=".TransactionNotificationListener"
            android:label="Zenith Transaction Detector"
            android:exported="false"
            android:permission="android.permission.BIND_NOTIFICATION_LISTENER_SERVICE">
            <intent-filter>
                <action android:name="android.service.notification.NotificationListenerService" />
            </intent-filter>
        </service>

        <meta-data android:name="flutterEmbedding" android:value="2" />
    </application>

    <queries>
        <intent>
            <action android:name="android.intent.action.PROCESS_TEXT" />
            <data android:mimeType="text/plain" />
        </intent>
    </queries>
</manifest>
MANIFEST

echo "✅ AndroidManifest.xml"

# ── App build.gradle.kts ──
cat > android/app/build.gradle.kts << 'BUILDGRADLE'
plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.zenith.zenith_budget"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }
    kotlinOptions { jvmTarget = JavaVersion.VERSION_11.toString() }

    defaultConfig {
        applicationId = "com.zenith.zenith_budget"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        multiDexEnabled = true
    }
    buildTypes {
        release { signingConfig = signingConfigs.getByName("debug") }
    }
}

flutter { source = "../.." }

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-auth")
    implementation("com.google.firebase:firebase-firestore")
}
BUILDGRADLE

echo "✅ app/build.gradle.kts"

# ── Project-level build.gradle.kts (add google services plugin) ──
# Check if settings.gradle.kts exists and update it
if [ -f android/settings.gradle.kts ]; then
  if ! grep -q "google-services" android/settings.gradle.kts; then
    sed -i '' 's/id("com.android.application")/id("com.android.application")\n        id("com.google.gms.google-services") version "4.4.2" apply false/' android/settings.gradle.kts 2>/dev/null || true
  fi
fi

# Also try the plugins block approach
cat > android/build.gradle.kts << 'PROJGRADLE'
allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
PROJGRADLE

echo "✅ project build.gradle.kts"

# ── Kotlin files ──
KOTLIN_DIR="android/app/src/main/kotlin/com/zenith/zenith_budget"

cat > $KOTLIN_DIR/TransactionNotificationListener.kt << 'NOTIFLISTENER'
package com.zenith.zenith_budget

import android.app.Notification
import android.content.Intent
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log

class TransactionNotificationListener : NotificationListenerService() {
    companion object {
        const val TAG = "ZenithNotif"
        const val ACTION_TRANSACTION = "com.zenith.zenith_budget.TRANSACTION_DETECTED"
        // ONLY payment and banking apps — no social media
        val PAYMENT_APPS = setOf(
            "com.google.android.apps.nbu.paisa.user",
            "com.google.android.apps.walletnfcrel",
            "com.phonepe.app",
            "net.one97.paytm",
            "in.org.npci.upiapp",
            "com.dreamplug.androidapp",
            "com.csam.icici.bank.imobile",
            "com.sbi.SBIFreedomPlus",
            "com.hdfcbank.hdfcquickbank",
            "com.axis.mobile",
            "com.msf.kbank.mobile",
            "com.kotak.mobile.banking"
        )
        // SMS apps — but we filter content for bank messages only
        val SMS_APPS = setOf(
            "com.google.android.apps.messaging",
            "com.nothing.messaging",
            "com.samsung.android.messaging",
            "com.android.mms"
        )
        val BANK_KEYWORDS = listOf("debited", "credited", "sent rs", "received rs", "payment of", "paid rs",
            "withdrawn", "transferred", "a/c", "upi", "neft", "imps", "rtgs", "txn", "transaction")
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val pkg = sbn.packageName

        // Skip if not a payment or SMS app
        val isPaymentApp = pkg in PAYMENT_APPS
        val isSmsApp = pkg in SMS_APPS
        if (!isPaymentApp && !isSmsApp) return

        val extras = sbn.notification?.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString() ?: ""
        val fullText = "$title $text $bigText".trim()
        if (fullText.isBlank()) return

        // For SMS apps, only process if it looks like a bank message
        if (isSmsApp) {
            val lower = fullText.lowercase()
            val isBankMsg = BANK_KEYWORDS.any { lower.contains(it) }
            if (!isBankMsg) return
        }

        Log.d(TAG, "Payment notification from $pkg: $fullText")
        val result = TransactionParser.parse(fullText, pkg)
        if (result != null) {
            Log.d(TAG, "✅ ${result.type}: ${result.amount} -> ${result.merchant}")
            val intent = Intent(ACTION_TRANSACTION).apply {
                putExtra("amount", result.amount)
                putExtra("merchant", result.merchant)
                putExtra("type", result.type)
                putExtra("source", result.source)
                putExtra("raw", fullText)
                setPackage(packageName)
            }
            sendBroadcast(intent)
        }
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification?) {}
    override fun onListenerConnected() { Log.d(TAG, "✅ Listener active") }
    override fun onListenerDisconnected() { Log.d(TAG, "⚠️ Listener disconnected") }
}
NOTIFLISTENER

cat > $KOTLIN_DIR/TransactionParser.kt << 'PARSER'
package com.zenith.zenith_budget

object TransactionParser {
    data class ParsedTransaction(val amount: Double, val merchant: String, val type: String, val source: String)

    fun parse(text: String, packageName: String): ParsedTransaction? {
        val lower = text.lowercase().trim()
        val source = when {
            packageName.contains("nbu.paisa") || packageName.contains("walletnfcrel") -> "gpay"
            packageName.contains("phonepe") -> "phonepe"
            packageName.contains("paytm") -> "paytm"
            packageName.contains("messaging") || packageName.contains("mms") || packageName.contains("nothing") -> "bank_sms"
            else -> "other"
        }
        val amount = extractAmount(lower) ?: return null
        if (amount <= 0 || amount > 10000000) return null
        val merchant = extractMerchant(lower)
        val isCredit = lower.contains("credited") || lower.contains("received") || lower.contains("refund") || lower.contains("deposit")
        val isDebit = lower.contains("sent") || lower.contains("paid") || lower.contains("debited") || lower.contains("spent") || lower.contains("withdrawn") || lower.contains("transferred") || lower.contains("deducted")
        if (!isCredit && !isDebit) return ParsedTransaction(amount, merchant, "debit", source)
        return ParsedTransaction(amount, merchant, if (isCredit && !isDebit) "credit" else "debit", source)
    }

    private fun extractAmount(text: String): Double? {
        val p = Regex("""(?:rs\.?\s*|inr\s*|[₹]\s*)([\d,]+\.?\d*)""", RegexOption.IGNORE_CASE)
        return p.find(text)?.groupValues?.get(1)?.replace(",", "")?.toDoubleOrNull()
    }

    private fun extractMerchant(text: String): String {
        val patterns = listOf(
            Regex("""to\s+([A-Za-z][A-Za-z0-9\s&'.]+?)(?:\s+on|\s+via|\s+ref|\s+from|[.]|$)""", RegexOption.IGNORE_CASE),
            Regex("""from\s+([A-Za-z][A-Za-z0-9\s&'.]+?)(?:\s+on|\s+via|\s+ref|[.]|$)""", RegexOption.IGNORE_CASE),
            Regex("""vpa[:\s]+(\S+)""", RegexOption.IGNORE_CASE)
        )
        for (p in patterns) {
            val m = p.find(text)
            if (m != null && m.groupValues[1].trim().length > 2) {
                return m.groupValues[1].trim().split(" ").joinToString(" ") { it.replaceFirstChar { c -> c.uppercase() } }.take(50)
            }
        }
        return "Unknown"
    }
}
PARSER

cat > $KOTLIN_DIR/MainActivity.kt << 'MAINACTIVITY'
package com.zenith.zenith_budget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        const val METHOD_CHANNEL = "com.zenith.budget/methods"
        const val EVENT_CHANNEL = "com.zenith.budget/transactions"
    }
    private var receiver: BroadcastReceiver? = null
    private var eventSink: EventChannel.EventSink? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "isNotificationAccessGranted" -> result.success(isNotifEnabled())
                "openNotificationAccessSettings" -> { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)); result.success(true) }
                else -> result.notImplemented()
            }
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, events: EventChannel.EventSink?) { eventSink = events; registerRcv() }
                override fun onCancel(args: Any?) { eventSink = null; unregisterRcv() }
            })
    }

    private fun isNotifEnabled(): Boolean {
        val flat = Settings.Secure.getString(contentResolver, "enabled_notification_listeners")
        return flat?.contains(packageName) == true
    }

    private fun registerRcv() {
        if (receiver != null) return
        receiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context?, intent: Intent?) {
                if (intent?.action != TransactionNotificationListener.ACTION_TRANSACTION) return
                eventSink?.success(mapOf(
                    "amount" to intent.getDoubleExtra("amount", 0.0),
                    "merchant" to (intent.getStringExtra("merchant") ?: "Unknown"),
                    "type" to (intent.getStringExtra("type") ?: "debit"),
                    "source" to (intent.getStringExtra("source") ?: "unknown"),
                    "timestamp" to System.currentTimeMillis()))
            }
        }
        val filter = IntentFilter(TransactionNotificationListener.ACTION_TRANSACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) registerReceiver(receiver, filter, RECEIVER_NOT_EXPORTED)
        else registerReceiver(receiver, filter)
    }

    private fun unregisterRcv() { receiver?.let { try { unregisterReceiver(it) } catch (_: Exception) {} }; receiver = null }
    override fun onDestroy() { unregisterRcv(); super.onDestroy() }
}
MAINACTIVITY

echo "✅ Kotlin files"

# ── Flutter main.dart ──
cat > lib/main.dart << 'DARTMAIN'
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:local_auth/local_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  runApp(const ZenithApp());
}

// ═══════════════════════════════════════════════════════════
// DATABASE SERVICE
// ═══════════════════════════════════════════════════════════

class DbService {
  static Database? _db;

  static Future<Database> get db async {
    if (_db != null) return _db!;
    final dbPath = await getDatabasesPath();
    _db = await openDatabase(p.join(dbPath, 'zenith.db'), version: 2,
      onCreate: (db, v) async {
        await db.execute('''CREATE TABLE transactions(
          id TEXT PRIMARY KEY, amount REAL, merchant TEXT, category TEXT,
          account TEXT, type TEXT, date TEXT, note TEXT)''');
        await db.execute('''CREATE TABLE merchant_map(
          merchant TEXT PRIMARY KEY, category TEXT)''');
        await db.execute('''CREATE TABLE custom_categories(
          id TEXT PRIMARY KEY, name TEXT, icon TEXT, color INTEGER, budget REAL)''');
      },
      onUpgrade: (db, oldV, newV) async {
        if (oldV < 2) {
          await db.execute('CREATE TABLE IF NOT EXISTS merchant_map(merchant TEXT PRIMARY KEY, category TEXT)');
          await db.execute('CREATE TABLE IF NOT EXISTS custom_categories(id TEXT PRIMARY KEY, name TEXT, icon TEXT, color INTEGER, budget REAL)');
        }
      });
    return _db!;
  }

  // Transactions
  static Future<void> insertTxn(Map<String, dynamic> txn) async {
    final d = await db;
    await d.insert('transactions', txn, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<void> updateTxn(Map<String, dynamic> txn) async {
    final d = await db;
    await d.update('transactions', txn, where: 'id = ?', whereArgs: [txn['id']]);
  }

  static Future<void> deleteTxn(String id) async {
    final d = await db;
    await d.delete('transactions', where: 'id = ?', whereArgs: [id]);
  }

  static Future<List<Map<String, dynamic>>> getAllTxns() async {
    final d = await db;
    return d.query('transactions', orderBy: 'date DESC');
  }

  // Merchant auto-categorize map
  static Future<String?> getMerchantCategory(String merchant) async {
    final d = await db;
    final r = await d.query('merchant_map', where: 'merchant = ?', whereArgs: [merchant.toLowerCase()]);
    if (r.isNotEmpty) return r.first['category'] as String;
    return null;
  }

  static Future<void> setMerchantCategory(String merchant, String category) async {
    final d = await db;
    await d.insert('merchant_map', {'merchant': merchant.toLowerCase(), 'category': category}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
}

// ═══════════════════════════════════════════════════════════
// CLOUD BACKUP SERVICE
// ═══════════════════════════════════════════════════════════

class CloudService {
  static final _fs = FirebaseFirestore.instance;

  static String? get uid => FirebaseAuth.instance.currentUser?.uid;

  static Future<void> backupTransaction(Map<String, dynamic> txn) async {
    if (uid == null) return;
    try { await _fs.collection('users').doc(uid).collection('transactions').doc(txn['id']).set(txn); } catch (_) {}
  }

  static Future<List<Map<String, dynamic>>> restoreTransactions() async {
    if (uid == null) return [];
    try {
      final snap = await _fs.collection('users').doc(uid).collection('transactions').orderBy('date', descending: true).get();
      return snap.docs.map((d) => d.data()).toList();
    } catch (_) { return []; }
  }

  static Future<void> backupMerchantMap(String merchant, String category) async {
    if (uid == null) return;
    try { await _fs.collection('users').doc(uid).collection('merchant_map').doc(merchant.toLowerCase()).set({'category': category}); } catch (_) {}
  }

  static Future<void> restoreMerchantMap() async {
    if (uid == null) return;
    try {
      final snap = await _fs.collection('users').doc(uid).collection('merchant_map').get();
      for (var doc in snap.docs) { await DbService.setMerchantCategory(doc.id, doc.data()['category']); }
    } catch (_) {}
  }
}

// ═══════════════════════════════════════════════════════════
// AUTH SERVICE
// ═══════════════════════════════════════════════════════════

class AuthService {
  static final _auth = FirebaseAuth.instance;
  static final _google = GoogleSignIn();

  static User? get currentUser => _auth.currentUser;
  static bool get isLoggedIn => _auth.currentUser != null;

  static Future<User?> signInWithGoogle() async {
    try {
      final gUser = await _google.signIn();
      if (gUser == null) return null;
      final gAuth = await gUser.authentication;
      final credential = GoogleAuthProvider.credential(accessToken: gAuth.accessToken, idToken: gAuth.idToken);
      final result = await _auth.signInWithCredential(credential);
      return result.user;
    } catch (e) { debugPrint('Google sign in error: $e'); return null; }
  }

  static Future<void> signOut() async {
    await _google.signOut();
    await _auth.signOut();
  }
}

// ═══════════════════════════════════════════════════════════
// NATIVE BRIDGE
// ═══════════════════════════════════════════════════════════

class NativeBridge {
  static const _methods = MethodChannel('com.zenith.budget/methods');
  static const _events = EventChannel('com.zenith.budget/transactions');
  static Future<bool> isNotifGranted() async { try { return await _methods.invokeMethod('isNotificationAccessGranted') ?? false; } catch (_) { return false; } }
  static Future<void> openNotifSettings() async { try { await _methods.invokeMethod('openNotificationAccessSettings'); } catch (_) {} }
  static Stream<Map<String, dynamic>> get txnStream => _events.receiveBroadcastStream().map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{});
}

// ═══════════════════════════════════════════════════════════
// DATA MODELS
// ═══════════════════════════════════════════════════════════

class Txn {
  String id; double amount; String merchant, category, account, type, note; DateTime date;
  Txn({required this.id, required this.amount, required this.merchant, required this.category, required this.account, required this.type, required this.date, this.note = ''});
  Map<String, dynamic> toMap() => {'id': id, 'amount': amount, 'merchant': merchant, 'category': category, 'account': account, 'type': type, 'date': date.toIso8601String(), 'note': note};
  factory Txn.fromMap(Map<String, dynamic> m) => Txn(id: m['id'], amount: (m['amount'] as num).toDouble(), merchant: m['merchant'] ?? '', category: m['category'] ?? 'other', account: m['account'] ?? 'gpay', type: m['type'] ?? 'expense', date: DateTime.tryParse(m['date'] ?? '') ?? DateTime.now(), note: m['note'] ?? '');
}

class Cat {
  final String id, name, icon; final Color color; final double budget; final bool isCustom;
  Cat(this.id, this.name, this.icon, this.color, this.budget, {this.isCustom = false});
}

final defaultCategories = <Cat>[
  Cat("food", "Food & Dining", "🍕", const Color(0xFFFF6B35), 8000),
  Cat("transport", "Transport", "🚗", const Color(0xFF00D4FF), 3000),
  Cat("shopping", "Shopping", "🛍️", const Color(0xFFA855F7), 5000),
  Cat("entertainment", "Entertainment", "🎬", const Color(0xFFF43F5E), 2000),
  Cat("groceries", "Groceries", "🥦", const Color(0xFF22C55E), 6000),
  Cat("bills", "Bills & Utilities", "💡", const Color(0xFFEAB308), 10000),
  Cat("health", "Health", "💊", const Color(0xFF06B6D4), 3000),
  Cat("education", "Education", "📚", const Color(0xFF8B5CF6), 4000),
  Cat("subscriptions", "Subscriptions", "📱", const Color(0xFFEC4899), 1500),
  Cat("travel", "Travel", "✈️", const Color(0xFFF97316), 5000),
  Cat("rent", "Rent & Housing", "🏠", const Color(0xFF14B8A6), 15000),
  Cat("savings", "Savings", "💰", const Color(0xFF10B981), 10000),
  Cat("personal", "Personal", "✨", const Color(0xFFD946EF), 2000),
  Cat("gifts", "Gifts", "🎁", const Color(0xFFF59E0B), 1500),
  Cat("other", "Other", "📌", const Color(0xFF64748B), 2000),
];

final incomeCats = <Cat>[
  Cat("salary", "Salary", "💼", const Color(0xFF22C55E), 0),
  Cat("freelance", "Freelance", "💻", const Color(0xFF3B82F6), 0),
  Cat("business", "Business", "🏢", const Color(0xFF8B5CF6), 0),
  Cat("investment", "Investment", "📈", const Color(0xFF10B981), 0),
  Cat("refund", "Refund", "↩️", const Color(0xFF06B6D4), 0),
  Cat("other_income", "Other", "💵", const Color(0xFF64748B), 0),
];

final accentColors = [const Color(0xFF00D4FF), const Color(0xFFA855F7), const Color(0xFF10B981), const Color(0xFFF43F5E), const Color(0xFFF59E0B), const Color(0xFF3B82F6), const Color(0xFF84CC16), const Color(0xFFEC4899)];

String fmt(double n) => NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0).format(n);
Cat? findCat(String id, List<Cat> cats) => cats.where((c) => c.id == id).firstOrNull;

// ═══════════════════════════════════════════════════════════
// APP
// ═══════════════════════════════════════════════════════════

class ZenithApp extends StatefulWidget {
  const ZenithApp({super.key});
  @override State<ZenithApp> createState() => _ZenithAppState();
}

class _ZenithAppState extends State<ZenithApp> {
  ThemeMode _mode = ThemeMode.dark;
  Color _accent = const Color(0xFF00D4FF);

  @override void initState() { super.initState(); _loadPrefs(); }
  Future<void> _loadPrefs() async {
    final p = await SharedPreferences.getInstance();
    setState(() { _mode = p.getString('theme') == 'light' ? ThemeMode.light : ThemeMode.dark; _accent = accentColors[(p.getInt('accent') ?? 0).clamp(0, 7)]; });
  }
  void toggleTheme() async { final p = await SharedPreferences.getInstance(); setState(() { _mode = _mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark; p.setString('theme', _mode == ThemeMode.light ? 'light' : 'dark'); }); }
  void setAccent(int i) async { final p = await SharedPreferences.getInstance(); setState(() { _accent = accentColors[i.clamp(0, 7)]; p.setInt('accent', i); }); }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Zenith', debugShowCheckedModeBanner: false, themeMode: _mode,
    theme: ThemeData(brightness: Brightness.light, colorSchemeSeed: _accent, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFFF5F5F7), textTheme: GoogleFonts.outfitTextTheme(ThemeData.light().textTheme)),
    darkTheme: ThemeData(brightness: Brightness.dark, colorSchemeSeed: _accent, useMaterial3: true, scaffoldBackgroundColor: const Color(0xFF0A0A14), textTheme: GoogleFonts.outfitTextTheme(ThemeData.dark().textTheme)),
    home: AuthGate(accent: _accent, onToggleTheme: toggleTheme, onSetAccent: setAccent, isDark: _mode == ThemeMode.dark));
}

// ═══════════════════════════════════════════════════════════
// AUTH GATE — Login / Biometric / Name entry
// ═══════════════════════════════════════════════════════════

class AuthGate extends StatefulWidget {
  final Color accent; final VoidCallback onToggleTheme; final ValueChanged<int> onSetAccent; final bool isDark;
  const AuthGate({super.key, required this.accent, required this.onToggleTheme, required this.onSetAccent, required this.isDark});
  @override State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool _loading = true, _authenticated = false;
  String _userName = '';

  @override void initState() { super.initState(); _init(); }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _userName = prefs.getString('user_name') ?? '';

    if (AuthService.isLoggedIn && _userName.isNotEmpty) {
      await _tryBiometric();
    }
    setState(() => _loading = false);
  }

  Future<void> _tryBiometric() async {
    final prefs = await SharedPreferences.getInstance();
    final bioEnabled = prefs.getBool('biometric') ?? false;
    if (!bioEnabled) { setState(() => _authenticated = true); return; }
    try {
      final auth = LocalAuthentication();
      final canAuth = await auth.canCheckBiometrics || await auth.isDeviceSupported();
      if (canAuth) {
        final ok = await auth.authenticate(localizedReason: 'Unlock Zenith', options: const AuthenticationOptions(biometricOnly: false));
        setState(() => _authenticated = ok);
      } else { setState(() => _authenticated = true); }
    } catch (_) { setState(() => _authenticated = true); }
  }

  Future<void> _signIn() async {
    setState(() => _loading = true);
    final user = await AuthService.signInWithGoogle();
    if (user != null) {
      final prefs = await SharedPreferences.getInstance();
      if (_userName.isEmpty) {
        _userName = user.displayName ?? '';
        prefs.setString('user_name', _userName);
      }
      // Restore data from cloud
      final cloudTxns = await CloudService.restoreTransactions();
      for (var t in cloudTxns) { await DbService.insertTxn(t); }
      await CloudService.restoreMerchantMap();
      await _tryBiometric();
    }
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Scaffold(body: Center(child: CircularProgressIndicator(color: widget.accent)));

    if (!AuthService.isLoggedIn) return _LoginScreen(accent: widget.accent, onSignIn: _signIn);

    if (_userName.isEmpty) return _NameEntryScreen(accent: widget.accent, onDone: (name) async {
      final prefs = await SharedPreferences.getInstance();
      prefs.setString('user_name', name);
      setState(() { _userName = name; _authenticated = true; });
    });

    if (!_authenticated) return _LockScreen(accent: widget.accent, onUnlock: _tryBiometric);

    return MainShell(accent: widget.accent, onToggleTheme: widget.onToggleTheme, onSetAccent: widget.onSetAccent, isDark: widget.isDark, userName: _userName);
  }
}

// ═══════════════════════════════════════════════════════════
// LOGIN SCREEN
// ═══════════════════════════════════════════════════════════

class _LoginScreen extends StatelessWidget {
  final Color accent; final VoidCallback onSignIn;
  const _LoginScreen({required this.accent, required this.onSignIn});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Text('Z', style: GoogleFonts.jetBrainsMono(fontSize: 72, fontWeight: FontWeight.w900, color: accent)),
      const SizedBox(height: 8),
      Text('ZENITH', style: GoogleFonts.outfit(fontSize: 28, fontWeight: FontWeight.w900, color: cs.onSurface, letterSpacing: 4)),
      const SizedBox(height: 8),
      Text('Smart Budget Tracker', style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.5))),
      const SizedBox(height: 60),
      SizedBox(width: double.infinity, height: 56, child: ElevatedButton.icon(
        onPressed: onSignIn,
        icon: const Text('G', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        label: const Text('Sign in with Google', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
        style: ElevatedButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))))),
      const SizedBox(height: 24),
      Text('Your data syncs across devices', style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.35))),
    ]))));
  }
}

// ═══════════════════════════════════════════════════════════
// NAME ENTRY SCREEN
// ═══════════════════════════════════════════════════════════

class _NameEntryScreen extends StatefulWidget {
  final Color accent; final ValueChanged<String> onDone;
  const _NameEntryScreen({required this.accent, required this.onDone});
  @override State<_NameEntryScreen> createState() => _NameEntryScreenState();
}

class _NameEntryScreenState extends State<_NameEntryScreen> {
  String _name = '';
  bool _bioEnabled = false;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Text('👋', style: const TextStyle(fontSize: 56)),
      const SizedBox(height: 16),
      Text("What's your name?", style: GoogleFonts.outfit(fontSize: 24, fontWeight: FontWeight.w800, color: cs.onSurface)),
      const SizedBox(height: 24),
      TextField(onChanged: (v) => setState(() => _name = v), textCapitalization: TextCapitalization.words, style: GoogleFonts.outfit(fontSize: 20, fontWeight: FontWeight.w600),
        decoration: InputDecoration(hintText: 'Enter your name', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none), contentPadding: const EdgeInsets.all(18))),
      const SizedBox(height: 20),
      Row(children: [
        Switch(value: _bioEnabled, onChanged: (v) async { setState(() => _bioEnabled = v); final p = await SharedPreferences.getInstance(); p.setBool('biometric', v); }, activeColor: widget.accent),
        const SizedBox(width: 8),
        Expanded(child: Text('Enable biometric lock', style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.7)))),
        Icon(Icons.fingerprint_rounded, color: cs.onSurface.withOpacity(0.3)),
      ]),
      const SizedBox(height: 32),
      SizedBox(width: double.infinity, height: 56, child: ElevatedButton(
        onPressed: _name.trim().length >= 2 ? () => widget.onDone(_name.trim()) : null,
        style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
        child: const Text("Let's go!", style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)))),
    ]))));
  }
}

// ═══════════════════════════════════════════════════════════
// LOCK SCREEN
// ═══════════════════════════════════════════════════════════

class _LockScreen extends StatelessWidget {
  final Color accent; final VoidCallback onUnlock;
  const _LockScreen({required this.accent, required this.onUnlock});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.lock_rounded, size: 64, color: accent),
      const SizedBox(height: 16),
      Text('Zenith is Locked', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w800, color: cs.onSurface)),
      const SizedBox(height: 24),
      ElevatedButton.icon(onPressed: onUnlock, icon: const Icon(Icons.fingerprint_rounded), label: const Text('Unlock', style: TextStyle(fontWeight: FontWeight.w700)),
        style: ElevatedButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)))),
    ])));
  }
}

// ═══════════════════════════════════════════════════════════
// MAIN SHELL
// ═══════════════════════════════════════════════════════════

class MainShell extends StatefulWidget {
  final Color accent; final VoidCallback onToggleTheme; final ValueChanged<int> onSetAccent; final bool isDark; final String userName;
  const MainShell({super.key, required this.accent, required this.onToggleTheme, required this.onSetAccent, required this.isDark, required this.userName});
  @override State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _tab = 0;
  List<Txn> _txns = [];
  StreamSubscription? _sub;
  bool _notifOk = false;
  bool _loading = true;

  @override void initState() { super.initState(); _load(); _listen(); _checkNotif(); }

  Future<void> _load() async {
    final maps = await DbService.getAllTxns();
    setState(() { _txns = maps.map((m) => Txn.fromMap(m)).toList(); _loading = false; });
  }

  void _listen() {
    _sub = NativeBridge.txnStream.listen((data) async {
      final amount = (data['amount'] as num?)?.toDouble() ?? 0;
      final merchant = data['merchant'] as String? ?? 'Unknown';
      final type = data['type'] as String? ?? 'debit';
      final source = data['source'] as String? ?? 'unknown';

      // Check if merchant has auto-category
      final autoCat = await DbService.getMerchantCategory(merchant);
      if (autoCat != null) {
        // Auto-categorize without popup
        final txn = Txn(id: DateTime.now().millisecondsSinceEpoch.toString(), amount: amount, merchant: merchant, category: autoCat, account: source == 'gpay' ? 'gpay' : 'bank', type: type == 'debit' ? 'expense' : 'income', date: DateTime.now());
        await _saveTxn(txn);
      } else if (mounted) {
        _showCatSheet(amount, merchant, type, source);
      }
    });
  }

  Future<void> _checkNotif() async { _notifOk = await NativeBridge.isNotifGranted(); if (mounted) setState(() {}); }

  Future<void> _saveTxn(Txn txn) async {
    await DbService.insertTxn(txn.toMap());
    await CloudService.backupTransaction(txn.toMap());
    await DbService.setMerchantCategory(txn.merchant, txn.category);
    await CloudService.backupMerchantMap(txn.merchant, txn.category);
    await _load();
  }

  void _showCatSheet(double amount, String merchant, String type, String source) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => _CatSheet(amount: amount, merchant: merchant, isExpense: type == 'debit', accent: widget.accent,
        onSelect: (catId, note) async {
          final txn = Txn(id: DateTime.now().millisecondsSinceEpoch.toString(), amount: amount, merchant: merchant, category: catId, account: source == 'gpay' ? 'gpay' : 'bank', type: type == 'debit' ? 'expense' : 'income', date: DateTime.now(), note: note);
          await _saveTxn(txn);
          if (ctx.mounted) Navigator.pop(ctx);
        }));
  }

  void _showAddSheet() {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => _AddSheet(accent: widget.accent, onAdd: (txn) async { await _saveTxn(txn); if (ctx.mounted) Navigator.pop(ctx); }));
  }

  void _showEditSheet(Txn txn) {
    showModalBottomSheet(context: context, isScrollControlled: true, backgroundColor: Colors.transparent,
      builder: (ctx) => _EditSheet(txn: txn, accent: widget.accent, onSave: (updated) async {
        await DbService.updateTxn(updated.toMap());
        await CloudService.backupTransaction(updated.toMap());
        await _load();
        if (ctx.mounted) Navigator.pop(ctx);
      }, onDelete: () async {
        await DbService.deleteTxn(txn.id);
        await _load();
        if (ctx.mounted) Navigator.pop(ctx);
      }));
  }

  double get totalExp => _txns.where((t) => t.type == 'expense').fold(0.0, (s, t) => s + t.amount);
  double get totalInc => _txns.where((t) => t.type == 'income').fold(0.0, (s, t) => s + t.amount);
  double get totalBudget => defaultCategories.fold(0.0, (s, c) => s + c.budget);

  @override void dispose() { _sub?.cancel(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Scaffold(body: Center(child: CircularProgressIndicator(color: widget.accent)));
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      body: [
        _HomeTab(txns: _txns, accent: widget.accent, isDark: widget.isDark, userName: widget.userName, totalExp: totalExp, totalInc: totalInc, totalBudget: totalBudget, notifOk: _notifOk, onToggleTheme: widget.onToggleTheme, onSetAccent: widget.onSetAccent, onRequestNotif: () async { await NativeBridge.openNotifSettings(); Future.delayed(const Duration(seconds: 2), _checkNotif); }, onAdd: _showAddSheet, onTap: _showEditSheet),
        _ActivityTab(txns: _txns, accent: widget.accent, onTap: _showEditSheet),
        _BudgetsTab(txns: _txns, accent: widget.accent),
        _StatsTab(txns: _txns, accent: widget.accent, totalExp: totalExp, totalInc: totalInc),
        _AccountsTab(txns: _txns, accent: widget.accent, notifOk: _notifOk),
      ][_tab],
      floatingActionButton: FloatingActionButton(onPressed: _showAddSheet, backgroundColor: widget.accent, child: const Icon(Icons.add, color: Colors.white)),
      bottomNavigationBar: NavigationBar(selectedIndex: _tab, onDestinationSelected: (i) => setState(() => _tab = i), indicatorColor: widget.accent.withOpacity(0.15),
        destinations: const [NavigationDestination(icon: Icon(Icons.home_rounded), label: 'Home'), NavigationDestination(icon: Icon(Icons.swap_vert_rounded), label: 'Activity'), NavigationDestination(icon: Icon(Icons.pie_chart_rounded), label: 'Budgets'), NavigationDestination(icon: Icon(Icons.analytics_rounded), label: 'Stats'), NavigationDestination(icon: Icon(Icons.account_balance_wallet_rounded), label: 'Accounts')]),
    );
  }
}

// ═══════════════════════════════════════════════════════════
// CATEGORIZE SHEET
// ═══════════════════════════════════════════════════════════

class _CatSheet extends StatefulWidget {
  final double amount; final String merchant; final bool isExpense; final Color accent; final Function(String, String) onSelect;
  const _CatSheet({required this.amount, required this.merchant, required this.isExpense, required this.accent, required this.onSelect});
  @override State<_CatSheet> createState() => _CatSheetState();
}

class _CatSheetState extends State<_CatSheet> {
  String _note = '';
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cats = widget.isExpense ? defaultCategories : incomeCats;
    return Container(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.82),
      decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const SizedBox(height: 12), Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2))),
        const SizedBox(height: 16),
        Container(margin: const EdgeInsets.symmetric(horizontal: 16), padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), gradient: const LinearGradient(colors: [Color(0x204285F4), Color(0x1034A853)]), border: Border.all(color: const Color(0x404285F4))),
          child: Row(children: [Container(width: 32, height: 32, decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), gradient: const LinearGradient(colors: [Color(0xFF4285F4), Color(0xFF34A853), Color(0xFFFBBC05), Color(0xFFEA4335)])), child: const Center(child: Text('G', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 14)))),
            const SizedBox(width: 10), Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(widget.isExpense ? 'PAYMENT SENT' : 'PAYMENT RECEIVED', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.4), letterSpacing: 0.5)), Text('Just now', style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.6)))])])),
        const SizedBox(height: 16),
        Text(widget.isExpense ? '-${fmt(widget.amount)}' : '+${fmt(widget.amount)}', style: GoogleFonts.jetBrainsMono(fontSize: 32, fontWeight: FontWeight.w800, color: widget.isExpense ? const Color(0xFFF43F5E) : const Color(0xFF22C55E))),
        const SizedBox(height: 4),
        Text.rich(TextSpan(children: [TextSpan(text: widget.isExpense ? 'Paid to ' : 'Received from ', style: TextStyle(color: cs.onSurface.withOpacity(0.5))), TextSpan(text: widget.merchant, style: TextStyle(fontWeight: FontWeight.w700, color: cs.onSurface))])),
        Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 0), child: TextField(onChanged: (v) => _note = v, decoration: InputDecoration(hintText: 'Add a note (optional)', prefixIcon: Icon(Icons.edit_note_rounded, color: cs.onSurface.withOpacity(0.3)), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none)))),
        Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 0), child: Text('Next time, this merchant auto-categorizes', style: TextStyle(fontSize: 10, color: widget.accent, fontWeight: FontWeight.w600))),
        const SizedBox(height: 10),
        Flexible(child: GridView.builder(padding: const EdgeInsets.fromLTRB(16, 0, 16, 24), shrinkWrap: true,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 1.1), itemCount: cats.length,
          itemBuilder: (_, i) { final c = cats[i]; return GestureDetector(onTap: () => widget.onSelect(c.id, _note),
            child: Container(decoration: BoxDecoration(color: c.color.withOpacity(0.08), borderRadius: BorderRadius.circular(12), border: Border.all(color: c.color.withOpacity(0.2))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(c.icon, style: const TextStyle(fontSize: 22)), const SizedBox(height: 4), Text(c.name, style: TextStyle(fontSize: 9, color: cs.onSurface.withOpacity(0.6)), textAlign: TextAlign.center, maxLines: 2)]))); })),
      ]));
  }
}

// ═══════════════════════════════════════════════════════════
// HELPER: Transaction Tile
// ═══════════════════════════════════════════════════════════

Widget txnTile(Txn txn, ColorScheme cs, {VoidCallback? onTap}) {
  final allCats = [...defaultCategories, ...incomeCats];
  final cat = findCat(txn.category, allCats);
  final icon = cat?.icon ?? '📌'; final name = cat?.name ?? 'Other'; final color = cat?.color ?? const Color(0xFF64748B);
  final isInc = txn.type == 'income';
  return GestureDetector(onTap: onTap, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
    child: Container(padding: const EdgeInsets.all(12), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface, border: Border.all(color: cs.outline.withOpacity(0.06))),
      child: Row(children: [
        Container(width: 40, height: 40, decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), color: color.withOpacity(0.12)), child: Center(child: Text(icon, style: const TextStyle(fontSize: 18)))),
        const SizedBox(width: 11),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(txn.merchant, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: cs.onSurface)), const SizedBox(height: 2),
          Row(children: [Text('$name · ${DateFormat.jm().format(txn.date)}', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.4))), if (txn.note.isNotEmpty) ...[const SizedBox(width: 4), Icon(Icons.sticky_note_2_rounded, size: 11, color: cs.onSurface.withOpacity(0.3))]]),
          if (txn.note.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(txn.note, style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.35), fontStyle: FontStyle.italic), maxLines: 1, overflow: TextOverflow.ellipsis)),
        ])),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(isInc ? '+${fmt(txn.amount)}' : '-${fmt(txn.amount)}', style: GoogleFonts.jetBrainsMono(fontSize: 14, fontWeight: FontWeight.w700, color: isInc ? const Color(0xFF22C55E) : cs.onSurface)),
          if (isInc) Text('Received', style: TextStyle(fontSize: 9, color: const Color(0xFF22C55E).withOpacity(0.7), fontWeight: FontWeight.w600)),
        ])]))));
}

// ═══════════════════════════════════════════════════════════
// HOME TAB
// ═══════════════════════════════════════════════════════════

class _HomeTab extends StatefulWidget {
  final List<Txn> txns; final Color accent; final bool isDark, notifOk; final String userName;
  final double totalExp, totalInc, totalBudget;
  final VoidCallback onToggleTheme, onRequestNotif, onAdd; final ValueChanged<int> onSetAccent; final ValueChanged<Txn> onTap;
  const _HomeTab({required this.txns, required this.accent, required this.isDark, required this.notifOk, required this.userName, required this.totalExp, required this.totalInc, required this.totalBudget, required this.onToggleTheme, required this.onSetAccent, required this.onRequestNotif, required this.onAdd, required this.onTap});
  @override State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> {
  bool _showColors = false;
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final pct = widget.totalBudget > 0 ? (widget.totalExp / widget.totalBudget).clamp(0.0, 1.0) : 0.0;
    final balance = widget.totalInc - widget.totalExp;
    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 100), children: [
      Padding(padding: const EdgeInsets.fromLTRB(18, 12, 18, 0), child: Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Hello, ${widget.userName}', style: TextStyle(fontSize: 13, color: cs.onSurface.withOpacity(0.5))), Text('ZENITH', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w900, color: cs.onSurface))]),
        Row(children: [GestureDetector(onTap: widget.onToggleTheme, child: Container(width: 38, height: 38, decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), color: cs.surface, border: Border.all(color: cs.outline.withOpacity(0.1))), child: Icon(widget.isDark ? Icons.wb_sunny_rounded : Icons.dark_mode_rounded, size: 18, color: cs.onSurface))),
          const SizedBox(width: 6), GestureDetector(onTap: () => setState(() => _showColors = !_showColors), child: Container(width: 38, height: 38, decoration: BoxDecoration(borderRadius: BorderRadius.circular(11), color: cs.surface, border: Border.all(color: cs.outline.withOpacity(0.1))), child: Icon(Icons.palette_rounded, size: 18, color: cs.onSurface)))])])),
      if (_showColors) Container(margin: const EdgeInsets.fromLTRB(16, 10, 16, 0), padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface, border: Border.all(color: cs.outline.withOpacity(0.1))),
        child: Wrap(spacing: 8, runSpacing: 8, children: List.generate(8, (i) { final c = accentColors[i]; return GestureDetector(onTap: () => widget.onSetAccent(i), child: Container(width: 36, height: 36, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(10), border: Border.all(color: c.value == widget.accent.value ? cs.onSurface : Colors.transparent, width: 2.5)), child: c.value == widget.accent.value ? const Icon(Icons.check, color: Colors.white, size: 18) : null)); }))),
      if (!widget.notifOk) GestureDetector(onTap: widget.onRequestNotif, child: Container(margin: const EdgeInsets.fromLTRB(16, 14, 16, 0), padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: const Color(0xFFF43F5E).withOpacity(0.1), border: Border.all(color: const Color(0xFFF43F5E).withOpacity(0.3))),
        child: Row(children: [const Icon(Icons.notifications_active_rounded, color: Color(0xFFF43F5E), size: 22), const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Enable Auto-Detection', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: cs.onSurface)), Text('Grant notification access to track GPay payments', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.5)))])), Icon(Icons.arrow_forward_ios_rounded, size: 14, color: cs.onSurface.withOpacity(0.3))]))),
      Container(margin: const EdgeInsets.fromLTRB(16, 14, 16, 0), padding: const EdgeInsets.all(22), decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), gradient: LinearGradient(colors: [widget.accent.withOpacity(0.1), Colors.purple.withOpacity(0.05)]), border: Border.all(color: widget.accent.withOpacity(0.2))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('BALANCE', style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4), letterSpacing: 1, fontWeight: FontWeight.w600)), const SizedBox(height: 4),
          Text(fmt(balance), style: GoogleFonts.jetBrainsMono(fontSize: 32, fontWeight: FontWeight.w900, color: balance >= 0 ? widget.accent : const Color(0xFFF43F5E))), const SizedBox(height: 14),
          Row(children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('INCOME', style: TextStyle(fontSize: 9, color: cs.onSurface.withOpacity(0.4), letterSpacing: 0.5, fontWeight: FontWeight.w600)), Text('+${fmt(widget.totalInc)}', style: GoogleFonts.jetBrainsMono(fontSize: 14, fontWeight: FontWeight.w700, color: const Color(0xFF22C55E)))]),
            const SizedBox(width: 24),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('EXPENSES', style: TextStyle(fontSize: 9, color: cs.onSurface.withOpacity(0.4), letterSpacing: 0.5, fontWeight: FontWeight.w600)), Text('-${fmt(widget.totalExp)}', style: GoogleFonts.jetBrainsMono(fontSize: 14, fontWeight: FontWeight.w700, color: const Color(0xFFF43F5E)))])])])),
      // Budget ring
      Container(margin: const EdgeInsets.fromLTRB(16, 14, 16, 0), padding: const EdgeInsets.all(20), decoration: BoxDecoration(borderRadius: BorderRadius.circular(20), color: cs.surface, border: Border.all(color: cs.outline.withOpacity(0.1))),
        child: Row(children: [
          SizedBox(width: 100, height: 100, child: TweenAnimationBuilder<double>(tween: Tween(begin: 0, end: pct), duration: const Duration(milliseconds: 1200), curve: Curves.easeOutCubic,
            builder: (_, v, __) => Stack(alignment: Alignment.center, children: [SizedBox(width: 100, height: 100, child: CircularProgressIndicator(value: v, strokeWidth: 8, strokeCap: StrokeCap.round, backgroundColor: cs.outline.withOpacity(0.08), valueColor: AlwaysStoppedAnimation(v > 0.9 ? const Color(0xFFF43F5E) : widget.accent))),
              Column(mainAxisSize: MainAxisSize.min, children: [Text('${(v * 100).round()}%', style: GoogleFonts.jetBrainsMono(fontSize: 20, fontWeight: FontWeight.w800, color: cs.onSurface)), Text('used', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.4)))])]))),
          const SizedBox(width: 20),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Monthly Budget', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: cs.onSurface)), const SizedBox(height: 8),
            _row('Spent', fmt(widget.totalExp), cs.onSurface, cs), const SizedBox(height: 4),
            _row('Left', fmt((widget.totalBudget - widget.totalExp).clamp(0, double.infinity)), const Color(0xFF22C55E), cs)]))])),
      // AI Insight
      if (widget.txns.isNotEmpty) Container(margin: const EdgeInsets.fromLTRB(16, 14, 16, 0), padding: const EdgeInsets.all(16), decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: widget.accent.withOpacity(0.06), border: Border.all(color: widget.accent.withOpacity(0.15))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('💡', style: const TextStyle(fontSize: 18)), const SizedBox(width: 10),
          Expanded(child: Text(_getInsight(), style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.7), height: 1.5)))])),
      Padding(padding: const EdgeInsets.fromLTRB(18, 18, 18, 8), child: Text('Recent', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: cs.onSurface))),
      if (widget.txns.isEmpty) Padding(padding: const EdgeInsets.all(32), child: Center(child: Text('No transactions yet.\nMake a GPay payment to get started!', textAlign: TextAlign.center, style: TextStyle(color: cs.onSurface.withOpacity(0.35))))),
      ...widget.txns.take(8).map((t) => txnTile(t, cs, onTap: () => widget.onTap(t))),
    ]));
  }

  Widget _row(String l, String v, Color c, ColorScheme cs) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(l, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.4))), Text(v, style: GoogleFonts.jetBrainsMono(fontSize: 13, fontWeight: FontWeight.w700, color: c))]);

  String _getInsight() {
    if (widget.txns.isEmpty) return 'Start tracking to get insights!';
    final topCat = defaultCategories.map((c) => MapEntry(c, widget.txns.where((t) => t.type == 'expense' && t.category == c.id).fold(0.0, (s, t) => s + t.amount))).where((e) => e.value > 0).toList()..sort((a, b) => b.value.compareTo(a.value));
    if (topCat.isEmpty) return 'Great job keeping expenses low!';
    final top = topCat.first;
    final pct = widget.totalExp > 0 ? (top.value / widget.totalExp * 100).round() : 0;
    if (widget.totalInc > 0 && widget.totalExp > widget.totalInc * 0.8) return 'Heads up — you\'ve spent ${(widget.totalExp / widget.totalInc * 100).round()}% of your income. Consider cutting back on ${top.key.name}.';
    return 'Your biggest spend is ${top.key.name} (${top.key.icon}) at ${fmt(top.value)} — that\'s $pct% of total expenses.';
  }
}

// ═══════════════════════════════════════════════════════════
// ACTIVITY TAB
// ═══════════════════════════════════════════════════════════

class _ActivityTab extends StatelessWidget {
  final List<Txn> txns; final Color accent; final ValueChanged<Txn> onTap;
  const _ActivityTab({required this.txns, required this.accent, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 100), children: [
      Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Activity', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w800, color: cs.onSurface)), Text('${txns.length} transactions · Tap to edit', style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.4)))])),
      ...txns.map((t) => txnTile(t, cs, onTap: () => onTap(t))),
      if (txns.isEmpty) Padding(padding: const EdgeInsets.all(48), child: Center(child: Text('No transactions yet', style: TextStyle(color: cs.onSurface.withOpacity(0.3))))),
    ]));
  }
}

// ═══════════════════════════════════════════════════════════
// BUDGETS TAB
// ═══════════════════════════════════════════════════════════

class _BudgetsTab extends StatelessWidget {
  final List<Txn> txns; final Color accent;
  const _BudgetsTab({required this.txns, required this.accent});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 100), children: [
      Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 14), child: Text('Budgets', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w800, color: cs.onSurface))),
      ...defaultCategories.map((cat) {
        final spent = txns.where((t) => t.type == 'expense' && t.category == cat.id).fold(0.0, (s, t) => s + t.amount);
        if (spent == 0 && cat.budget == 0) return const SizedBox.shrink();
        final pct = cat.budget > 0 ? (spent / cat.budget).clamp(0.0, 1.0) : 0.0;
        return Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 3), padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), color: cs.surface, border: Border.all(color: cs.outline.withOpacity(0.06))),
          child: Column(children: [Row(children: [Text(cat.icon, style: const TextStyle(fontSize: 20)), const SizedBox(width: 10),
            Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(cat.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: cs.onSurface)), Text('${fmt(spent)} / ${fmt(cat.budget)}', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.4)))])),
            Text(spent > cat.budget ? 'Over!' : '${fmt(cat.budget - spent)} left', style: GoogleFonts.jetBrainsMono(fontSize: 11, fontWeight: FontWeight.w700, color: spent > cat.budget ? const Color(0xFFF43F5E) : const Color(0xFF22C55E)))]),
            const SizedBox(height: 8), ClipRRect(borderRadius: BorderRadius.circular(3), child: LinearProgressIndicator(value: pct, minHeight: 5, backgroundColor: cs.outline.withOpacity(0.1), valueColor: AlwaysStoppedAnimation(pct > 0.9 ? const Color(0xFFF43F5E) : cat.color)))])); }),
    ]));
  }
}

// ═══════════════════════════════════════════════════════════
// STATS TAB
// ═══════════════════════════════════════════════════════════

class _StatsTab extends StatelessWidget {
  final List<Txn> txns; final Color accent; final double totalExp, totalInc;
  const _StatsTab({required this.txns, required this.accent, required this.totalExp, required this.totalInc});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final sr = totalInc > 0 ? ((totalInc - totalExp) / totalInc * 100).round() : 0;
    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 100), children: [
      Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 14), child: Text('Analytics', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w800, color: cs.onSurface))),
      Container(margin: const EdgeInsets.symmetric(horizontal: 16), padding: const EdgeInsets.all(18), decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), gradient: LinearGradient(colors: [accent.withOpacity(0.1), Colors.purple.withOpacity(0.05)]), border: Border.all(color: accent.withOpacity(0.2))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Savings Rate', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: accent)), Text('$sr%', style: GoogleFonts.jetBrainsMono(fontSize: 32, fontWeight: FontWeight.w900, color: cs.onSurface)), Text('Saved ${fmt(totalInc - totalExp)} of ${fmt(totalInc)}', style: TextStyle(fontSize: 12, color: cs.onSurface.withOpacity(0.5)))])),
      Padding(padding: const EdgeInsets.fromLTRB(18, 18, 18, 8), child: Text('SPENDING', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.35), letterSpacing: 1))),
      ...defaultCategories.map((cat) {
        final spent = txns.where((t) => t.type == 'expense' && t.category == cat.id).fold(0.0, (s, t) => s + t.amount);
        if (spent == 0) return const SizedBox.shrink();
        final pct = totalExp > 0 ? spent / totalExp : 0.0;
        return Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3), child: Row(children: [Text(cat.icon, style: const TextStyle(fontSize: 16)), const SizedBox(width: 8),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text(cat.name, style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.6))), Text(fmt(spent), style: GoogleFonts.jetBrainsMono(fontSize: 11, fontWeight: FontWeight.w700, color: cat.color))]),
            const SizedBox(height: 3), ClipRRect(borderRadius: BorderRadius.circular(2), child: LinearProgressIndicator(value: pct, minHeight: 3, backgroundColor: cs.outline.withOpacity(0.08), valueColor: AlwaysStoppedAnimation(cat.color)))])),
          const SizedBox(width: 8), Text('${(pct * 100).round()}%', style: GoogleFonts.jetBrainsMono(fontSize: 10, color: cs.onSurface.withOpacity(0.35)))])); }),
    ]));
  }
}

// ═══════════════════════════════════════════════════════════
// ACCOUNTS TAB
// ═══════════════════════════════════════════════════════════

class _AccountsTab extends StatelessWidget {
  final List<Txn> txns; final Color accent; final bool notifOk;
  const _AccountsTab({required this.txns, required this.accent, required this.notifOk});
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final accs = [['gpay', 'Google Pay', 'G', 0xFF4285F4], ['cash', 'Cash', '₹', 0xFF22C55E], ['bank', 'Bank', 'B', 0xFF004C8F], ['credit', 'Credit Card', 'C', 0xFFF43F5E]];
    return SafeArea(child: ListView(padding: const EdgeInsets.only(bottom: 100), children: [
      Padding(padding: const EdgeInsets.fromLTRB(18, 16, 18, 14), child: Text('Accounts', style: GoogleFonts.outfit(fontSize: 22, fontWeight: FontWeight.w800, color: cs.onSurface))),
      ...accs.map((a) {
        final id = a[0] as String; final name = a[1] as String; final ic = a[2] as String; final color = Color(a[3] as int);
        final count = txns.where((t) => t.account == id).length;
        return Container(margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4), padding: const EdgeInsets.all(16), decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), color: cs.surface, border: Border.all(color: color.withOpacity(0.2))),
          child: Column(children: [Row(children: [Container(width: 44, height: 44, decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), color: color.withOpacity(0.12)), child: Center(child: Text(ic, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color)))),
            const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(name, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: cs.onSurface)), Text('$count transactions', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.4)))]))]),
            if (id == 'gpay') Container(margin: const EdgeInsets.only(top: 10), padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(9), color: const Color(0xFF4285F4).withOpacity(0.08)),
              child: Row(children: [Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: notifOk ? const Color(0xFF22C55E) : const Color(0xFFF43F5E))), const SizedBox(width: 8), Expanded(child: Text(notifOk ? 'Auto-detecting transactions' : 'Notification access not granted', style: TextStyle(fontSize: 10, color: cs.onSurface.withOpacity(0.5))))]))]));
      }),
    ]));
  }
}

// ═══════════════════════════════════════════════════════════
// ADD TRANSACTION SHEET
// ═══════════════════════════════════════════════════════════

class _AddSheet extends StatefulWidget {
  final Color accent; final ValueChanged<Txn> onAdd;
  const _AddSheet({required this.accent, required this.onAdd});
  @override State<_AddSheet> createState() => _AddSheetState();
}

class _AddSheetState extends State<_AddSheet> {
  bool _isExp = true; String _amt = '', _merch = '', _cat = '', _acc = 'gpay', _note = '';
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final cats = _isExp ? defaultCategories : incomeCats;
    final ok = _amt.isNotEmpty && _merch.isNotEmpty && _cat.isNotEmpty;
    return Container(constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.88), decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 34), children: [
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))), const SizedBox(height: 16),
        Text('Add Transaction', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: cs.onSurface)), const SizedBox(height: 14),
        Row(children: [
          Expanded(child: GestureDetector(onTap: () => setState(() { _isExp = true; _cat = ''; }), child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: _isExp ? const Color(0xFFF43F5E).withOpacity(0.1) : Colors.transparent, border: Border.all(color: _isExp ? const Color(0xFFF43F5E).withOpacity(0.3) : cs.outline.withOpacity(0.1))), child: Center(child: Text('💸 Expense', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: _isExp ? const Color(0xFFF43F5E) : cs.onSurface.withOpacity(0.4))))))),
          const SizedBox(width: 8),
          Expanded(child: GestureDetector(onTap: () => setState(() { _isExp = false; _cat = ''; }), child: Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(borderRadius: BorderRadius.circular(10), color: !_isExp ? const Color(0xFF22C55E).withOpacity(0.1) : Colors.transparent, border: Border.all(color: !_isExp ? const Color(0xFF22C55E).withOpacity(0.3) : cs.outline.withOpacity(0.1))), child: Center(child: Text('💰 Income', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13, color: !_isExp ? const Color(0xFF22C55E) : cs.onSurface.withOpacity(0.4))))))),
        ]), const SizedBox(height: 14),
        TextField(keyboardType: TextInputType.number, onChanged: (v) => setState(() => _amt = v), style: GoogleFonts.jetBrainsMono(fontSize: 28, fontWeight: FontWeight.w800), decoration: InputDecoration(hintText: '₹ 0', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 10),
        TextField(onChanged: (v) => setState(() => _merch = v), decoration: InputDecoration(hintText: _isExp ? 'Merchant' : 'Source', filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 10),
        TextField(onChanged: (v) => _note = v, decoration: InputDecoration(hintText: 'Note (optional)', prefixIcon: Icon(Icons.edit_note_rounded, color: cs.onSurface.withOpacity(0.3)), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 14),
        GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 7, crossAxisSpacing: 7, childAspectRatio: 1.15), itemCount: cats.length,
          itemBuilder: (_, i) { final c = cats[i]; final sel = _cat == c.id;
            return GestureDetector(onTap: () => setState(() => _cat = c.id), child: Container(decoration: BoxDecoration(color: sel ? c.color.withOpacity(0.15) : cs.outline.withOpacity(0.04), borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? c.color.withOpacity(0.4) : cs.outline.withOpacity(0.08))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(c.icon, style: const TextStyle(fontSize: 20)), const SizedBox(height: 3), Text(c.name, style: TextStyle(fontSize: 9, color: sel ? c.color : cs.onSurface.withOpacity(0.5), fontWeight: sel ? FontWeight.w700 : FontWeight.w400), textAlign: TextAlign.center, maxLines: 2)]))); }),
        const SizedBox(height: 18),
        ElevatedButton(onPressed: ok ? () => widget.onAdd(Txn(id: DateTime.now().millisecondsSinceEpoch.toString(), amount: double.tryParse(_amt) ?? 0, merchant: _merch, category: _cat, account: _acc, type: _isExp ? 'expense' : 'income', date: DateTime.now(), note: _note)) : null,
          style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.all(16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          child: Text('Add ${_isExp ? "Expense" : "Income"}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
      ]));
  }
}

// ═══════════════════════════════════════════════════════════
// EDIT TRANSACTION SHEET
// ═══════════════════════════════════════════════════════════

class _EditSheet extends StatefulWidget {
  final Txn txn; final Color accent; final ValueChanged<Txn> onSave; final VoidCallback onDelete;
  const _EditSheet({required this.txn, required this.accent, required this.onSave, required this.onDelete});
  @override State<_EditSheet> createState() => _EditSheetState();
}

class _EditSheetState extends State<_EditSheet> {
  late String _cat, _note;
  @override void initState() { super.initState(); _cat = widget.txn.category; _note = widget.txn.note; }
  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isInc = widget.txn.type == 'income';
    final cats = isInc ? incomeCats : defaultCategories;
    return Container(constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.75), decoration: BoxDecoration(color: cs.surface, borderRadius: const BorderRadius.vertical(top: Radius.circular(24))),
      child: ListView(padding: const EdgeInsets.fromLTRB(18, 12, 18, 34), children: [
        Center(child: Container(width: 40, height: 4, decoration: BoxDecoration(color: cs.outline.withOpacity(0.3), borderRadius: BorderRadius.circular(2)))), const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Edit Transaction', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: cs.onSurface)),
          TextButton(onPressed: widget.onDelete, child: const Text('Delete', style: TextStyle(color: Color(0xFFF43F5E), fontWeight: FontWeight.w700)))]),
        const SizedBox(height: 12),
        Text(isInc ? '+${fmt(widget.txn.amount)}' : '-${fmt(widget.txn.amount)}', style: GoogleFonts.jetBrainsMono(fontSize: 28, fontWeight: FontWeight.w800, color: isInc ? const Color(0xFF22C55E) : cs.onSurface)),
        Text(widget.txn.merchant, style: TextStyle(fontSize: 14, color: cs.onSurface.withOpacity(0.6))),
        Text(DateFormat('MMM d, y · h:mm a').format(widget.txn.date), style: TextStyle(fontSize: 11, color: cs.onSurface.withOpacity(0.35))),
        const SizedBox(height: 14),
        TextField(controller: TextEditingController(text: _note), onChanged: (v) => _note = v, decoration: InputDecoration(hintText: 'Note', prefixIcon: Icon(Icons.edit_note_rounded, color: cs.onSurface.withOpacity(0.3)), filled: true, fillColor: cs.outline.withOpacity(0.05), border: OutlineInputBorder(borderRadius: BorderRadius.circular(12), borderSide: BorderSide.none))),
        const SizedBox(height: 14),
        Text('CATEGORY', style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: cs.onSurface.withOpacity(0.35), letterSpacing: 1)), const SizedBox(height: 8),
        GridView.builder(shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, mainAxisSpacing: 7, crossAxisSpacing: 7, childAspectRatio: 1.15), itemCount: cats.length,
          itemBuilder: (_, i) { final c = cats[i]; final sel = _cat == c.id;
            return GestureDetector(onTap: () => setState(() => _cat = c.id), child: Container(decoration: BoxDecoration(color: sel ? c.color.withOpacity(0.15) : cs.outline.withOpacity(0.04), borderRadius: BorderRadius.circular(10), border: Border.all(color: sel ? c.color.withOpacity(0.4) : cs.outline.withOpacity(0.08))),
              child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(c.icon, style: const TextStyle(fontSize: 20)), const SizedBox(height: 3), Text(c.name, style: TextStyle(fontSize: 9, color: sel ? c.color : cs.onSurface.withOpacity(0.5), fontWeight: sel ? FontWeight.w700 : FontWeight.w400), textAlign: TextAlign.center, maxLines: 2)]))); }),
        const SizedBox(height: 18),
        ElevatedButton(onPressed: () { final updated = widget.txn..category = _cat..note = _note; widget.onSave(updated); },
          style: ElevatedButton.styleFrom(backgroundColor: widget.accent, foregroundColor: Colors.white, padding: const EdgeInsets.all(16), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
          child: const Text('Save Changes', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 15))),
      ]));
  }
}
DARTMAIN

echo "✅ main.dart"

# ── Update settings.gradle.kts for Firebase ──
if [ -f android/settings.gradle.kts ]; then
  if ! grep -q "google-services" android/settings.gradle.kts; then
    sed -i '' '/id("com.android.application")/a\
        id("com.google.gms.google-services") version "4.4.2" apply false
' android/settings.gradle.kts 2>/dev/null || true
  fi
fi

echo "✅ Firebase gradle config"

# ── Install dependencies ──
echo "📦 Installing packages..."
flutter pub get

echo ""
echo "════════════════════════════════════════════"
echo "✅ ZENITH PRODUCTION BUILD COMPLETE!"
echo "════════════════════════════════════════════"
echo ""
echo "To run on your phone:"
echo "  flutter run"
echo ""
echo "To build APK for friends:"
echo "  flutter build apk --release"
echo "  (APK at: build/app/outputs/flutter-apk/app-release.apk)"
echo ""
