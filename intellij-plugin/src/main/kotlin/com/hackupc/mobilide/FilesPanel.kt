package com.hackupc.mobilide

import com.intellij.openapi.application.ApplicationManager
import com.intellij.ui.JBColor
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBPanel
import com.intellij.ui.components.JBScrollPane
import com.intellij.ui.components.JBTextField
import com.intellij.util.ui.JBUI
import java.awt.*
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import java.awt.image.BufferedImage
import java.io.ByteArrayInputStream
import javax.imageio.ImageIO
import javax.swing.*

private const val THUMB = 90
private const val CARD_W = THUMB + 18
private const val CARD_H = THUMB + 44

class FilesPanel(private val client: BackendClient) : JBPanel<FilesPanel>(BorderLayout()) {
    private val searchField = JBTextField(22)
    private val searchBtn = PillButton("Search")
    private val refreshBtn = PillButton("↻")
    private val statusLabel = JBLabel(" ")
    private val gridPanel = JPanel(FlowLayout(FlowLayout.LEFT, 8, 8))

    init {
        isOpaque = false
        border = JBUI.Borders.empty(10)
        gridPanel.isOpaque = false

        val sectionLabel = JBLabel("RECENT FILES").apply {
            font = font.deriveFont(Font.BOLD, 10f); foreground = MUTED
        }
        val headerRow = JPanel(BorderLayout(6, 0)).apply {
            isOpaque = false; border = JBUI.Borders.empty(6, 0, 4, 0)
        }
        headerRow.add(sectionLabel, BorderLayout.WEST)
        headerRow.add(refreshBtn, BorderLayout.EAST)

        val searchRow = JPanel(BorderLayout(6, 0)).apply { isOpaque = false }
        searchRow.add(searchField, BorderLayout.CENTER)
        searchRow.add(searchBtn, BorderLayout.EAST)

        statusLabel.apply { font = font.deriveFont(10f); foreground = MUTED }

        val top = JPanel(BorderLayout()).apply { isOpaque = false }
        top.add(searchRow, BorderLayout.NORTH)
        top.add(headerRow, BorderLayout.CENTER)
        top.add(statusLabel, BorderLayout.SOUTH)

        val scroll = JBScrollPane(gridPanel).apply {
            border = JBUI.Borders.empty()
            isOpaque = false; viewport.isOpaque = false
            horizontalScrollBarPolicy = ScrollPaneConstants.HORIZONTAL_SCROLLBAR_NEVER
        }

        add(top, BorderLayout.NORTH)
        add(scroll, BorderLayout.CENTER)

        searchBtn.addActionListener { doSearch() }
        searchField.addActionListener { doSearch() }
        refreshBtn.addActionListener { loadRecent() }
        loadRecent()
    }

    fun loadRecent() {
        statusLabel.text = "Loading…"
        gridPanel.removeAll(); gridPanel.revalidate()
        client.listImages { images, error ->
            ApplicationManager.getApplication().invokeLater {
                statusLabel.text = " "
                if (error != null) { statusLabel.text = "Error: $error"; return@invokeLater }
                if (images.isNullOrEmpty()) statusLabel.text = "No files yet"
                else images.forEach { gridPanel.add(makeCard(it.id, it.filename, null)) }
                gridPanel.revalidate(); gridPanel.repaint()
            }
        }
    }

    private fun doSearch() {
        val q = searchField.text.trim()
        if (q.isEmpty()) { loadRecent(); return }
        statusLabel.text = "Searching…"
        gridPanel.removeAll(); gridPanel.revalidate()
        client.searchByText(q) { results, error ->
            ApplicationManager.getApplication().invokeLater {
                statusLabel.text = " "
                if (error != null) { statusLabel.text = "Error: $error"; return@invokeLater }
                if (results.isNullOrEmpty()) statusLabel.text = "No results for \"$q\""
                else results.forEach { gridPanel.add(makeCard(it.id, it.filename, it.score)) }
                gridPanel.revalidate(); gridPanel.repaint()
            }
        }
    }

    private fun makeCard(id: String, filename: String, score: Double?): JPanel {
        val hoverBg = JBColor(Color(234, 248, 240), Color(35, 52, 40))
        val cardHeight = CARD_H + if (score != null) 16 else 0

        val card = object : RoundedPanel(radius = 10) {
            init {
                layout = BoxLayout(this, BoxLayout.Y_AXIS)
                bg = CARD_BG; stroke = CARD_BORDER
                preferredSize = Dimension(CARD_W, cardHeight)
                maximumSize = preferredSize
            }
        }

        val ph = BufferedImage(THUMB, THUMB, BufferedImage.TYPE_INT_ARGB).also { img ->
            val g = img.createGraphics(); g.smooth()
            g.color = JBColor(Color(222, 222, 226), Color(60, 63, 67))
            g.fillRoundRect(0, 0, THUMB, THUMB, 6, 6)
            g.dispose()
        }
        var fullImage: BufferedImage? = null

        val imgLabel = object : JLabel(ImageIcon(ph)) {
            init {
                preferredSize = Dimension(THUMB, THUMB)
                minimumSize = Dimension(THUMB, THUMB)
                maximumSize = Dimension(THUMB, THUMB)
                horizontalAlignment = SwingConstants.CENTER
                alignmentX = Component.CENTER_ALIGNMENT
                cursor = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR)
                addMouseListener(object : MouseAdapter() {
                    override fun mouseClicked(e: MouseEvent) {
                        fullImage?.let { ImageViewerDialog(card, filename, it) }
                    }
                    override fun mouseEntered(e: MouseEvent) { card.bg = hoverBg; card.repaint() }
                    override fun mouseExited(e: MouseEvent) { card.bg = CARD_BG; card.repaint() }
                })
            }
        }

        val shortName = if (filename.length > 13) "${filename.take(11)}…" else filename
        val nameLabel = JBLabel(shortName).apply {
            font = font.deriveFont(10f)
            horizontalAlignment = SwingConstants.CENTER
            alignmentX = Component.CENTER_ALIGNMENT
            foreground = JBColor(Color(50, 52, 56), Color(200, 202, 206))
            border = JBUI.Borders.emptyTop(4)
        }

        val deleteBtn = object : JLabel("✕") {
            init {
                font = font.deriveFont(Font.BOLD, 9f)
                foreground = MUTED
                cursor = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR)
                alignmentX = Component.CENTER_ALIGNMENT
                border = JBUI.Borders.emptyTop(2)
                addMouseListener(object : MouseAdapter() {
                    override fun mouseEntered(e: MouseEvent) { foreground = JBColor(Color(195, 50, 50), Color(220, 80, 80)) }
                    override fun mouseExited(e: MouseEvent) { foreground = MUTED }
                    override fun mouseClicked(e: MouseEvent) {
                        statusLabel.text = "Deleting…"
                        client.deleteImage(id) { error ->
                            ApplicationManager.getApplication().invokeLater {
                                if (error != null) {
                                    statusLabel.text = "Error: $error"
                                } else {
                                    val parent = card.parent
                                    parent?.remove(card)
                                    parent?.revalidate()
                                    parent?.repaint()
                                    statusLabel.text = " "
                                }
                            }
                        }
                    }
                })
            }
        }

        card.add(Box.createVerticalStrut(6))
        card.add(imgLabel)
        if (score != null) {
            card.add(JBLabel("%.0f%%".format(score * 100)).apply {
                font = font.deriveFont(Font.BOLD, 9f)
                foreground = ACCENT
                horizontalAlignment = SwingConstants.CENTER
                alignmentX = Component.CENTER_ALIGNMENT
                border = JBUI.Borders.emptyTop(3)
            })
        }
        card.add(nameLabel)
        card.add(deleteBtn)
        card.add(Box.createVerticalStrut(4))

        client.fetchImageBytes(id) { bytes, _ ->
            if (bytes != null) try {
                val img = ImageIO.read(ByteArrayInputStream(bytes)) ?: return@fetchImageBytes
                fullImage = img
                val scaled = img.getScaledInstance(THUMB, THUMB, Image.SCALE_SMOOTH)
                ApplicationManager.getApplication().invokeLater {
                    imgLabel.icon = ImageIcon(scaled); card.repaint()
                }
            } catch (_: Exception) {}
        }
        return card
    }
}
