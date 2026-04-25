package com.hackupc.mobilide

import com.google.gson.JsonParser
import com.intellij.openapi.application.ApplicationManager
import com.intellij.openapi.components.Service
import com.intellij.openapi.fileEditor.FileEditorManager
import com.intellij.openapi.project.Project
import com.intellij.openapi.vfs.LocalFileSystem
import java.io.File
import java.net.URI
import java.net.http.HttpClient
import java.net.http.WebSocket
import java.util.concurrent.CompletionStage

@Service(Service.Level.PROJECT)
class SyncService(private val project: Project) {

    var webSocket: WebSocket? = null
    var onStatusChange: ((String) -> Unit)? = null
    var onIncomingChange: ((filename: String, code: String) -> Unit)? = null

    fun connect(url: String) {
        val client = HttpClient.newHttpClient()
        val listener = object : WebSocket.Listener {
            private val buffer = StringBuilder()

            override fun onOpen(ws: WebSocket) {
                ws.request(1)
                ws.sendText("""{"type":"plugin"}""", true)
                notifyStatus("Connected")
            }

            override fun onText(ws: WebSocket, data: CharSequence, last: Boolean): CompletionStage<*>? {
                buffer.append(data)
                if (last) {
                    handleMessage(buffer.toString())
                    buffer.clear()
                }
                ws.request(1)
                return null
            }

            override fun onClose(ws: WebSocket, statusCode: Int, reason: String): CompletionStage<*>? {
                webSocket = null
                notifyStatus("Disconnected")
                return null
            }

            override fun onError(ws: WebSocket, error: Throwable) {
                webSocket = null
                notifyStatus("Error: ${error.message}")
            }
        }

        try {
            client.newWebSocketBuilder()
                .buildAsync(URI.create(url), listener)
                .thenAccept { ws -> webSocket = ws }
        } catch (e: Exception) {
            notifyStatus("Failed: ${e.message}")
        }
    }

    fun disconnect() {
        webSocket?.sendClose(WebSocket.NORMAL_CLOSURE, "bye")
        webSocket = null
        notifyStatus("Disconnected")
    }

    fun sendCode(filename: String, code: String) {
        val ws = webSocket ?: return
        val json = buildJsonMessage(filename, code)
        ws.sendText(json, true)
    }

    private fun handleMessage(text: String) {
        try {
            val obj = JsonParser.parseString(text).asJsonObject
            val filename = obj.get("filename")?.asString ?: return
            val code = obj.get("code")?.asString ?: return
            writeFileToProject(filename, code)
            ApplicationManager.getApplication().invokeLater {
                onIncomingChange?.invoke(filename, code)
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

    private fun buildJsonMessage(filename: String, code: String): String {
        val escapedFilename = filename.replace("\\", "\\\\").replace("\"", "\\\"")
        val escapedCode = code.replace("\\", "\\\\").replace("\"", "\\\"")
            .replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
        return """{"filename":"$escapedFilename","code":"$escapedCode"}"""
    }

    private fun notifyStatus(status: String) {
        ApplicationManager.getApplication().invokeLater {
            onStatusChange?.invoke(status)
        }
    }

    companion object {
        fun getInstance(project: Project): SyncService = project.getService(SyncService::class.java)
    }
}
