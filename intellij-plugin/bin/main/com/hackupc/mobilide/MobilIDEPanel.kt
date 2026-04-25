package com.hackupc.mobilide

import com.intellij.openapi.project.Project
import com.intellij.ui.JBColor
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBPanel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.JBUI
import java.awt.*
import java.time.LocalTime
import java.time.format.DateTimeFormatter
import javax.swing.*

class MobilIDEPanel(project: Project) : JBPanel<MobilIDEPanel>(BorderLayout()) {
    private val sync = SyncService.getInstance(project)
    private val urlField = JBTextField("ws://localhost:8000/ws/sync")
    private val connectBtn = PillButton("Connect", primary = true)
    private val statusDot = StatusDot()
    private val statusText = JBLabel("Disconnected")
    private val changesContainer = JPanel()
    private val client = BackendClient { urlField.text.trim() }
    private val timeFmt = DateTimeFormatter.ofPattern("HH:mm:ss")

    init {
        isOpaque = false
        border = JBUI.Borders.empty(14)

        sync.onStatusChange = { status ->
            val ok = status == "Connected"
            statusDot.connected = ok; statusDot.repaint()
            statusText.text = status
            statusText.foreground = if (ok) ACCENT else MUTED
            connectBtn.text = if (ok) "Disconnect" else "Connect"
        }
        sync.onIncomingChange = { filename, code -> prependEntry(filename, code) }
        connectBtn.addActionListener {
            if (sync.webSocket != null) sync.disconnect() else sync.connect(urlField.text.trim())
        }

        val urlRow = JPanel(BorderLayout(8, 0)).apply { isOpaque = false }
        urlRow.add(urlField, BorderLayout.CENTER)
        urlRow.add(connectBtn, BorderLayout.EAST)

        val statusRow = JPanel(FlowLayout(FlowLayout.LEFT, 5, 0)).apply {
            isOpaque = false; border = JBUI.Borders.emptyTop(7)
        }
        statusText.apply { font = font.deriveFont(11f); foreground = MUTED }
        statusRow.add(statusDot)
        statusRow.add(statusText)

        val header = JPanel(BorderLayout()).apply {
            isOpaque = false; border = JBUI.Borders.emptyBottom(12)
        }
        header.add(urlRow, BorderLayout.NORTH)
        header.add(statusRow, BorderLayout.SOUTH)

        val cards = CardLayout()
        val content = JPanel(cards).apply { isOpaque = false }
        content.add(buildSyncPanel(), "sync")
        content.add(FilesPanel(client), "files")
        content.add(EmbedPanel(client), "embed")

        val tabNames = listOf("sync", "files", "embed")
        val tabBar = UnderlineTabBar(listOf("Sync", "Files", "Embed")) { i ->
            cards.show(content, tabNames[i])
        }

        val center = JPanel(BorderLayout()).apply { isOpaque = false }
        center.add(tabBar, BorderLayout.NORTH)
        center.add(content, BorderLayout.CENTER)

        add(header, BorderLayout.NORTH)
        add(center, BorderLayout.CENTER)
    }

    private fun buildSyncPanel(): JPanel {
        val label = JBLabel("INCOMING CHANGES").apply {
            font = font.deriveFont(Font.BOLD, 10f)
            foreground = MUTED
            border = JBUI.Borders.empty(10, 0, 8, 0)
        }
        changesContainer.layout = BoxLayout(changesContainer, BoxLayout.Y_AXIS)
        changesContainer.isOpaque = false

        val scroll = JBScrollPane(changesContainer).apply {
            border = JBUI.Borders.empty()
            isOpaque = false; viewport.isOpaque = false
            verticalScrollBarPolicy = ScrollPaneConstants.VERTICAL_SCROLLBAR_AS_NEEDED
            horizontalScrollBarPolicy = ScrollPaneConstants.HORIZONTAL_SCROLLBAR_NEVER
        }
        return JPanel(BorderLayout()).apply {
            isOpaque = false
            add(label, BorderLayout.NORTH)
            add(scroll, BorderLayout.CENTER)
        }
    }

    private fun prependEntry(filename: String, code: String) {
        val time = LocalTime.now().format(timeFmt)
        val preview = code.trim().take(160).let { if (code.trim().length > 160) "$it…" else it }

        val entry = object : JPanel(BorderLayout(0, 5)) {
            init { isOpaque = false; border = JBUI.Borders.empty(9, 12) }
            override fun paintComponent(g: Graphics) {
                val g2 = g.create() as Graphics2D
                g2.smooth()
                g2.color = JBColor(Color(240, 253, 244), Color(22, 38, 26))
                g2.fillRoundRect(0, 0, width, height, 10, 10)
                g2.color = ACCENT
                g2.fillRoundRect(0, 3, 3, height - 6, 3, 3)
                g2.dispose()
            }
        }

        val topRow = JPanel(BorderLayout()).apply { isOpaque = false }
        topRow.add(JBLabel(filename).apply {
            font = font.deriveFont(Font.BOLD, 12f); foreground = ACCENT
        }, BorderLayout.WEST)
        topRow.add(JBLabel(time).apply {
            font = font.deriveFont(10f); foreground = MUTED
        }, BorderLayout.EAST)

        val codeArea = JTextArea(preview).apply {
            font = Font(Font.MONOSPACED, Font.PLAIN, 11)
            foreground = JBColor(Color(25, 115, 55), Color(115, 210, 145))
            isOpaque = false; isEditable = false
            lineWrap = true; wrapStyleWord = true
            border = JBUI.Borders.emptyTop(3)
        }

        entry.add(topRow, BorderLayout.NORTH)
        entry.add(codeArea, BorderLayout.CENTER)

        val wrapper = JPanel(BorderLayout()).apply {
            isOpaque = false; border = JBUI.Borders.emptyBottom(6)
        }
        wrapper.add(entry)
        wrapper.maximumSize = Dimension(Int.MAX_VALUE, Int.MAX_VALUE)

        changesContainer.add(wrapper, 0)
        changesContainer.revalidate()
        changesContainer.repaint()
    }
}
