package app.web2app.sdk

import org.json.JSONObject
import java.net.URLEncoder

/**
 * Резолв guid из carrier-token или email. Стабильные backend-контракты (POC-независимо):
 *  - token → `GET /public/handoff/resolve?code=<token>` → { guid } (WEB-433).
 *  - email → verified-resolve (WEB-431, In Review — контракт финализируется при мёрдже).
 */
internal class AttributionResolver(private val config: Web2AppConfig) {

    fun resolveToken(token: String, onResult: (Result<String>) -> Unit) {
        Http.io {
            val q = URLEncoder.encode(token, "UTF-8")
            onResult(parseGuid(Http.get("${config.baseUrl}/public/handoff/resolve?code=$q")))
        }
    }

    fun resolveEmail(email: String, onResult: (Result<String>) -> Unit) {
        Http.io {
            val body = JSONObject()
                .put("projectId", config.projectId)
                .put("email", email)
                .toString()
            // ⚠ WEB-431 (email-ядро, In Review): точный путь recovery request/verify финализируется.
            val resp = Http.postJson("${config.baseUrl}/public/handoff/email-recovery/verify", body)
            onResult(parseGuid(resp))
        }
    }

    private fun parseGuid(body: String?): Result<String> {
        val guid = body?.let { runCatching { JSONObject(it).optString("guid") }.getOrNull() }
        return if (!guid.isNullOrEmpty()) Result.success(guid)
        else Result.failure(IllegalStateException("resolve failed"))
    }
}
