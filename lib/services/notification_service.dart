import 'package:flutter/services.dart';

// ═══ NATIVE BRIDGE ═══

class NB {
  static const _m = MethodChannel('com.zenith.budget/methods');
  static const _e = EventChannel('com.zenith.budget/transactions');
  static Future<bool> notifOk() async { try { return await _m.invokeMethod('isNotificationAccessGranted') ?? false; } catch (_) { return false; } }
  static Future<void> openNotif() async { try { await _m.invokeMethod('openNotificationAccessSettings'); } catch (_) {} }
  static Stream<Map<String, dynamic>> get stream => _e.receiveBroadcastStream().map((e) => e is Map ? Map<String, dynamic>.from(e) : <String, dynamic>{});
}