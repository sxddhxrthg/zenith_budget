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
        val amount = Regex("""(?:rs\.?\s*|inr\s*|₹\s*)([\d,]+\.?\d*)""", RegexOption.IGNORE_CASE).find(lower)?.groupValues?.get(1)?.replace(",","")?.toDoubleOrNull() ?: return null
        if (amount <= 0 || amount > 10000000) return null
        val cw = listOf("credited","received","deposited","refund","cashback")
        val dw = listOf("debited","sent","paid","spent","withdrawn","transferred","deducted","payment of")
        val hc = cw.any { lower.contains(it) }; val hd = dw.any { lower.contains(it) }
        val type = if (hc && hd) { val cp = cw.mapNotNull { w -> lower.indexOf(w).takeIf { it >= 0 } }.minOrNull() ?: Int.MAX_VALUE; val dp = dw.mapNotNull { w -> lower.indexOf(w).takeIf { it >= 0 } }.minOrNull() ?: Int.MAX_VALUE; if (cp < dp) "credit" else "debit" } else if (hc) "credit" else "debit"
        val kw = if (type == "credit") "from" else "to"
        val skip = listOf("view","a/c","ac/","bank","upi","ref","on","via","the","your","not")
        val merchant = listOf(Regex("""$kw\s+([A-Za-z][A-Za-z0-9\s&'.]+?)(?:\s+on|\s+via|\s+ref|\s+a/c|[.]|${'$'})""", RegexOption.IGNORE_CASE), Regex("""vpa[:\s]+([^\s]+)""", RegexOption.IGNORE_CASE))
            .firstNotNullOfOrNull { p -> p.find(lower)?.groupValues?.get(1)?.trim()?.takeIf { it.length > 2 && !skip.any { s -> it.lowercase() == s } } }
            ?.split(" ")?.joinToString(" ") { it.replaceFirstChar { c -> c.uppercase() } }?.take(40) ?: "Unknown"
        return ParsedTransaction(amount, merchant, type, source)
    }
}
