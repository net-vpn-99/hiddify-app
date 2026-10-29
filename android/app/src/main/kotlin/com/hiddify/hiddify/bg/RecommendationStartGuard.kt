package com.hiddify.hiddify.bg

import com.google.gson.JsonElement
import com.google.gson.JsonObject
import com.google.gson.JsonParser

/** Native boot/tile entry must not start a default route for an explicit empty decision. */
object RecommendationStartGuard {
    private const val PREFIX = "gsl-recommendation-v1:"
    private const val GROUP = "gsl-ln-v1:"

    fun blocksAutomaticStart(raw: String, manual: Boolean, decode: (String) -> String): Boolean {
        if (manual) return false
        return try {
            val root = JsonParser.parseString(raw).asJsonObject
            val outbounds = root.getAsJsonArray("outbounds") ?: return raw.contains(PREFIX)
            val markers = outbounds.filter { it.isJsonObject }.map { it.asJsonObject }.filter {
                text(it.get("type")) == "block" && text(it.get("tag"))?.startsWith(PREFIX) == true
            }
            if (markers.isEmpty()) return false
            if (markers.size != 1) return true
            val tag = text(markers.single().get("tag")) ?: return true
            if (!tag.endsWith("§hide§") || tag.length > 8192) return true
            val policy = JsonParser.parseString(decode(tag.removePrefix(PREFIX).removeSuffix("§hide§"))).asJsonObject
            if (!one(policy.get("schema")) || text(policy.get("status")) != "selected" || !policy.has("logical_id")) return true
            val id = if (policy.get("logical_id").isJsonNull) "" else text(policy.get("logical_id")) ?: return true
            val endpoint = policy.getAsJsonObject("endpoint") ?: return true
            val host = text(endpoint.get("host")) ?: return true
            val targetPort = port(endpoint.get("port")) ?: return true
            if (host.isEmpty() || host.length > 253 || host.any { it <= ' ' || it == '\u007f' }) return true
            if (id.isNotEmpty() && !Regex("[A-Za-z0-9_-]{1,64}").matches(id)) return true
            var matches = 0
            for (entry in outbounds) {
                if (!entry.isJsonObject) continue
                val node = entry.asJsonObject
                val nodeTag = text(node.get("tag")) ?: continue
                if (id.isNotEmpty()) {
                    if (!nodeTag.startsWith(GROUP)) continue
                    val group = JsonParser.parseString(decode(nodeTag.removePrefix(GROUP))).asJsonObject
                    if (text(group.get("id")) != id) continue
                    val endpoints = group.getAsJsonArray("endpoints") ?: continue
                    val valid = endpoints.count { e -> e.isJsonObject && endpointMatches(e.asJsonObject, host, targetPort) &&
                        e.asJsonObject.get("available")?.let { it.isJsonPrimitive && it.asJsonPrimitive.isBoolean && it.asBoolean } == true }
                    if (valid == 1) matches++
                } else if (!nodeTag.startsWith("gsl-ep-v1:") &&
                    text(node.get("type")) !in setOf("selector", "urltest", "direct", "block", "dns", "dns-out") &&
                    text(node.get("server"))?.equals(host, ignoreCase = true) == true && port(node.get("server_port")) == targetPort) matches++
            }
            matches != 1
        } catch (_: Exception) {
            raw.contains(PREFIX)
        }
    }

    private fun text(value: JsonElement?): String? =
        if (value?.isJsonPrimitive == true && value.asJsonPrimitive.isString) value.asString else null
    private fun one(value: JsonElement?): Boolean = value?.isJsonPrimitive == true && value.asJsonPrimitive.isNumber && value.asString == "1"
    private fun port(value: JsonElement?): Int? {
        if (value?.isJsonPrimitive != true || !value.asJsonPrimitive.isNumber || !Regex("[0-9]{1,5}").matches(value.asString)) return null
        return value.asInt.takeIf { it in 1..65535 }
    }
    private fun endpointMatches(value: JsonObject, host: String, expectedPort: Int): Boolean =
        text(value.get("host"))?.equals(host, ignoreCase = true) == true && port(value.get("port")) == expectedPort
}
