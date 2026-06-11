package com.zenith.zenith_budget

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {
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
