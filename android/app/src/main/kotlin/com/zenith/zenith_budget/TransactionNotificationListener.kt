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
        val PAYMENT_APPS = setOf(
            "com.google.android.apps.nbu.paisa.user", "com.google.android.apps.walletnfcrel",
            "com.phonepe.app", "net.one97.paytm", "in.org.npci.upiapp", "com.dreamplug.androidapp",
            "com.csam.icici.bank.imobile", "com.sbi.SBIFreedomPlus", "com.hdfcbank.hdfcquickbank",
            "com.axis.mobile", "com.msf.kbank.mobile", "com.kotak.mobile.banking")
        val SMS_APPS = setOf("com.google.android.apps.messaging", "com.nothing.messaging", "com.samsung.android.messaging", "com.android.mms")
        val BANK_KW = listOf("debited", "credited", "sent rs", "received rs", "payment of", "paid rs", "withdrawn", "transferred", "a/c", "upi", "neft", "imps", "txn")
    }
    private val recent = mutableListOf<Pair<Double, Long>>()
    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        val pkg = sbn.packageName
        val isPay = pkg in PAYMENT_APPS; val isSms = pkg in SMS_APPS
        if (!isPay && !isSms) return
        val extras = sbn.notification?.extras ?: return
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString() ?: ""
        val text = extras.getCharSequence(Notification.EXTRA_TEXT)?.toString() ?: ""
        val big = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString() ?: ""
        val full = "$title $text $big".trim()
        if (full.isBlank()) return
        if (isSms && !BANK_KW.any { full.lowercase().contains(it) }) return
        val r = TransactionParser.parse(full, pkg) ?: return
        val now = System.currentTimeMillis()
        recent.removeAll { now - it.second > 10000 }
        if (recent.any { it.first == r.amount }) return
        recent.add(Pair(r.amount, now))
        Log.d(TAG, ">>> ${r.type}: Rs.${r.amount} -> ${r.merchant}")
        sendBroadcast(Intent(ACTION_TRANSACTION).apply {
            putExtra("amount", r.amount); putExtra("merchant", r.merchant)
            putExtra("type", r.type); putExtra("source", r.source)
            putExtra("raw", full); setPackage(packageName) })
    }
    override fun onNotificationRemoved(sbn: StatusBarNotification?) {}
    override fun onListenerConnected() { Log.d(TAG, "Listener active") }
}
