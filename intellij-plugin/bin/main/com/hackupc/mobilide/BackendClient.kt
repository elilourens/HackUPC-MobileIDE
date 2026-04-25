package com.hackupc.mobilide

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.io.File
import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.file.Files

data class ImageEntry(val id: String, val filename: String, val description: String)
data class FileSearchResult(val id: String, val filename: String, val description: String, val score: Double)
data class EmbedResult(val id: String, val description: String, val dimensions: Int)

class BackendClient(private val getWsUrl: () -> String) {
    private val http = HttpClient.newHttpClient()
    private val gson = Gson()

    private val baseUrl get() = getWsUrl()
        .replace(Regex("^ws://"), "http://")
        .replace(Regex("^wss://"), "https://")
        .substringBefore("/ws/")
        .ifEmpty { "http://localhost:8000" }

    fun listImages(callback: (List<ImageEntry>?, String?) -> Unit) {
        val req = HttpRequest.newBuilder().uri(URI.create("$baseUrl/images?sort=newest")).GET().build()
        http.sendAsync(req, HttpResponse.BodyHandlers.ofString())
            .thenAccept { res ->
                if (res.statusCode() == 200) {
                    val type = object : TypeToken<List<ImageEntry>>() {}.type
                    callback(gson.fromJson(res.body(), type), null)
                } else {
                    callback(null, "HTTP ${res.statusCode()}")
                }
            }
            .exceptionally { e -> callback(null, e.cause?.message ?: e.message); null }
    }

    fun searchByText(query: String, callback: (List<FileSearchResult>?, String?) -> Unit) {
        val encoded = URLEncoder.encode(query, "UTF-8")
        val req = HttpRequest.newBuilder()
            .uri(URI.create("$baseUrl/search/text?query=$encoded"))
            .POST(HttpRequest.BodyPublishers.noBody())
            .build()
        http.sendAsync(req, HttpResponse.BodyHandlers.ofString())
            .thenAccept { res ->
                if (res.statusCode() == 200) {
                    val type = object : TypeToken<List<FileSearchResult>>() {}.type
                    callback(gson.fromJson(res.body(), type), null)
                } else {
                    callback(null, "HTTP ${res.statusCode()}")
                }
            }
            .exceptionally { e -> callback(null, e.cause?.message ?: e.message); null }
    }

    fun embedImage(file: File, callback: (EmbedResult?, String?) -> Unit) {
        Thread {
            try {
                val boundary = "AetherBoundary${System.currentTimeMillis()}"
                val mime = Files.probeContentType(file.toPath())
                    ?: if (file.name.lowercase().endsWith(".png")) "image/png" else "image/jpeg"

                val conn = (java.net.URL("$baseUrl/embed/image").openConnection()
                        as java.net.HttpURLConnection).apply {
                    doOutput = true
                    requestMethod = "POST"
                    setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
                }

                conn.outputStream.use { out ->
                    out.write("--$boundary\r\n".toByteArray(Charsets.US_ASCII))
                    out.write("Content-Disposition: form-data; name=\"file\"; filename=\"${file.name}\"\r\n".toByteArray(Charsets.US_ASCII))
                    out.write("Content-Type: $mime\r\n\r\n".toByteArray(Charsets.US_ASCII))
                    out.write(file.readBytes())
                    out.write("\r\n--$boundary--\r\n".toByteArray(Charsets.US_ASCII))
                }

                val status = conn.responseCode
                val body = if (status == 200) conn.inputStream.bufferedReader().readText()
                           else conn.errorStream?.bufferedReader()?.readText() ?: ""
                conn.disconnect()

                if (status == 200) callback(gson.fromJson(body, EmbedResult::class.java), null)
                else callback(null, "HTTP $status: ${body.take(120)}")
            } catch (e: Exception) {
                callback(null, e.message)
            }
        }.start()
    }

    fun fetchImageBytes(id: String, callback: (ByteArray?, String?) -> Unit) {
        val req = HttpRequest.newBuilder().uri(URI.create("$baseUrl/images/$id")).GET().build()
        http.sendAsync(req, HttpResponse.BodyHandlers.ofByteArray())
            .thenAccept { res ->
                if (res.statusCode() == 200) callback(res.body(), null)
                else callback(null, "HTTP ${res.statusCode()}")
            }
            .exceptionally { e -> callback(null, e.cause?.message ?: e.message); null }
    }

    fun deleteImage(id: String, callback: (String?) -> Unit) {
        val req = HttpRequest.newBuilder()
            .uri(URI.create("$baseUrl/images/$id"))
            .DELETE()
            .build()
        http.sendAsync(req, HttpResponse.BodyHandlers.ofString())
            .thenAccept { res ->
                if (res.statusCode() == 200) callback(null)
                else callback("HTTP ${res.statusCode()}")
            }
            .exceptionally { e -> callback(e.cause?.message ?: e.message); null }
    }

}
