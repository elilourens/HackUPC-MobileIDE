package com.hackupc.mobilide

import com.intellij.openapi.editor.Document
import com.intellij.openapi.fileEditor.FileDocumentManager
import com.intellij.openapi.fileEditor.FileDocumentManagerListener
import com.intellij.openapi.project.ProjectLocator

class FileSaveListener : FileDocumentManagerListener {
    override fun beforeDocumentSaving(document: Document) {
        val vf = FileDocumentManager.getInstance().getFile(document) ?: return
        val project = ProjectLocator.getInstance().guessProjectForFile(vf) ?: return
        val sync = SyncService.getInstance(project)
        if (sync.webSocket == null) return
        sync.sendCode(vf.name, document.text)
    }
}
