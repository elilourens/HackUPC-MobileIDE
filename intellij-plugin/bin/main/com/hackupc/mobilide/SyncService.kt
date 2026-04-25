package com.hackupc.mobilide

import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import com.intellij.openapi.fileEditor.FileEditorManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.LocalFileSystem
import java.io.File
import java.net.URI
import java.net.URLEncoder
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

@Service(Service.Level.PROJECT)
class SyncService(private val project: Project) {

    var isConnected = false
        private set
    var onStatusChange: ((String) -> Unit)? = null
    var onIncomingChange: ((filename: String, code: String) -> Unit)? = null

    private val http = HttpClient.newHttpClient()
    private val gson = Gson()
    private var baseUrl = ""
    private var lastSeen: String? = null
    private var scheduler: ScheduledExecutorService? = null

    fun connect(url: String) {
        baseUrl = normalizeUrl(url)
        isConnected = true
        lastSeen = java.time.Instant.now().toString()
        notifyStatus("Connected")
        startPolling()
    }

    fun disconnect() {
        isConnected = false
        stopPolling()
        notifyStatus("Disconnected")
    }

    fun sendCode(filename: String, code: String) {
        val body = gson.toJson(mapOf(
            "filename" to filename,
            "content" to code,
            "edit_type" to "plugin"
        ))
        val req = HttpRequest.newBuilder()
            .uri(URI.create("$baseUrl/code-edits"))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(body))
            .build()
        http.sendAsync(req, HttpResponse.BodyHandlers.ofString()).exceptionally { null }
    }

    private fun startPolling() {
        scheduler = Executors.newSingleThreadScheduledExecutor()
        scheduler?.scheduleWithFixedDelay({ poll() }, 0, 1500, TimeUnit.MILLISECONDS)
    }

    private fun stopPolling() {
        scheduler?.shutdownNow()
        scheduler = null
    }

    private fun poll() {
        if (!isConnected) return
        try {
            val params = buildString {
                append("source=ios")
                lastSeen?.let { append("&since="); append(URLEncoder.encode(it, "UTF-8")) }
            }
            val req = HttpRequest.newBuilder()
                .uri(URI.create("$baseUrl/code-edits?$params"))
                .GET().build()
            val res = http.send(req, HttpResponse.BodyHandlers.ofString())
            if (res.statusCode() != 200) return
            val type = object : TypeToken<List<Map<String, Any?>>>() {}.type
            val edits: List<Map<String, Any?>> = gson.fromJson(res.body(), type)
            for (edit in edits) {
                val filename = edit["filename"] as? String ?: continue
                val content = edit["content"] as? String ?: continue
                val createdAt = edit["created_at"] as? String ?: continue
                writeFileToProject(filename, content)
                ApplicationManager.getApplication().invokeLater {
                    onIncomingChange?.invoke(filename, content)
                }
                lastSeen = createdAt
            }
        } catch (_: Exception) {}
    }

    private fun writeFileToProject(filename: String, code: String) {
        val projectPath = project.basePath ?: return
        val file = File(projectPath, filename)
        file.parentFile?.mkdirs()
        file.writeText(code)
        ApplicationManager.getApplication().invokeLater {
            val vf = LocalFileSystem.getInstance().refreshAndFindFileByIoFile(file)
            if (vf != null) {
                vf.refresh(false, false)
                FileEditorManager.getInstance(project).openFile(vf, true)
            }
        }
    }

    private fun normalizeUrl(url: String) = url
        .replace(Regex("^ws://"), "http://")
        .replace(Regex("^wss://"), "https://")
        .substringBefore("/ws/")
        .trimEnd('/')
        .ifEmpty { "http://localhost:8000" }

    private fun notifyStatus(status: String) {
        ApplicationManager.getApplication().invokeLater {
            onStatusChange?.invoke(status)
        }
    }

    companion object {
        fun getInstance(project: Project): SyncService = project.getService(SyncService::class.java)
    }
}
