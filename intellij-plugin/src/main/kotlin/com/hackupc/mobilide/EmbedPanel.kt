package com.hackupc.mobilide

import com.intellij.openapi.application.ApplicationManager
import com.intellij.ui.JBColor
import com.intellij.ui.components.JBLabel
import com.intellij.ui.components.JBPanel
import com.intellij.ui.components.JBScrollPane
import com.intellij.util.ui.JBUI
import java.awt.*
import java.awt.datatransfer.DataFlavor
import java.awt.dnd.*
import java.io.File
import javax.swing.*

class EmbedPanel(private val client: BackendClient) : JBPanel<EmbedPanel>(BorderLayout()) {
    private val statusLabel = JBLabel("Drop an image file to embed it")
    private val descArea = JTextArea()
    private val dropZone = DropZone()
    private val clearBtn = PillButton("Clear")

    init {
        isOpaque = false
        border = JBUI.Borders.empty(12)

        val label = JBLabel("EMBED FILE").apply {
            font = font.deriveFont(Font.BOLD, 10f)
            foreground = MUTED
        }

        clearBtn.apply {
            isVisible = false
            addActionListener { resetState() }
        }

        val labelRow = JPanel(BorderLayout()).apply {
            isOpaque = false; border = JBUI.Borders.emptyBottom(10)
            add(label, BorderLayout.WEST)
            add(clearBtn, BorderLayout.EAST)
        }

        statusLabel.apply {
            horizontalAlignment = SwingConstants.CENTER
            font = font.deriveFont(12f)
            foreground = MUTED
        }
        dropZone.add(statusLabel, BorderLayout.CENTER)

        descArea.apply {
            isEditable = false; lineWrap = true; wrapStyleWord = true
            font = Font(Font.MONOSPACED, Font.PLAIN, 11)
            border = JBUI.Borders.empty(10)
            isOpaque = false
            foreground = JBColor(Color(50, 52, 56), Color(200, 202, 206))
        }

        val descPanel = RoundedPanel(BorderLayout(), radius = 10).apply {
            bg = CARD_BG; stroke = CARD_BORDER
            add(JBScrollPane(descArea).apply {
                border = JBUI.Borders.empty()
                isOpaque = false; viewport.isOpaque = false
            })
        }

        val top = JPanel(BorderLayout()).apply {
            isOpaque = false; border = JBUI.Borders.emptyBottom(10)
            add(labelRow, BorderLayout.NORTH)
            add(dropZone, BorderLayout.CENTER)
        }
        add(top, BorderLayout.NORTH)
        add(descPanel, BorderLayout.CENTER)

        DropTarget(dropZone, object : DropTargetAdapter() {
            override fun dragEnter(e: DropTargetDragEvent) {
                e.acceptDrag(DnDConstants.ACTION_COPY); dropZone.hovered = true; dropZone.repaint()
            }
            override fun dragExit(e: DropTargetEvent) {
                dropZone.hovered = false; dropZone.repaint()
            }
            override fun drop(e: DropTargetDropEvent) {
                e.acceptDrop(DnDConstants.ACTION_COPY)
                dropZone.hovered = false; dropZone.repaint()
                if (e.transferable.isDataFlavorSupported(DataFlavor.javaFileListFlavor)) {
                    @Suppress("UNCHECKED_CAST")
                    (e.transferable.getTransferData(DataFlavor.javaFileListFlavor) as List<File>)
                        .firstOrNull()?.let { handleDrop(it) }
                }
                e.dropComplete(true)
            }
        })
    }

    private fun resetState() {
        statusLabel.text = "Drop an image file to embed it"
        statusLabel.foreground = MUTED
        descArea.text = ""
        clearBtn.isVisible = false
    }

    private fun handleDrop(file: File) {
        statusLabel.text = "Embedding ${file.name}…"
        statusLabel.foreground = MUTED
        descArea.text = ""
        clearBtn.isVisible = false
        client.embedImage(file) { result, error ->
            ApplicationManager.getApplication().invokeLater {
                if (error != null) {
                    statusLabel.text = "✕  ${error.take(70)}"
                    statusLabel.foreground = JBColor(Color(195, 50, 50), Color(220, 80, 80))
                    clearBtn.isVisible = true
                } else if (result != null) {
                    statusLabel.text = "✓  ${file.name}  ·  ${result.dimensions}d vector"
                    statusLabel.foreground = ACCENT
                    descArea.text = result.description
                    clearBtn.isVisible = true
                }
            }
        }
    }

    private inner class DropZone : JPanel(BorderLayout()) {
        var hovered = false
        private val normalBg  get() = JBColor(Color(248, 248, 251), Color(44, 46, 50))
        private val hoveredBg get() = JBColor(Color(232, 248, 238), Color(24, 46, 30))

        init {
            isOpaque = false
            preferredSize = Dimension(0, 120)
            border = JBUI.Borders.empty(12)
        }

        override fun paintComponent(g: Graphics) {
            val g2 = g.create() as Graphics2D
            g2.smooth()
            g2.color = if (hovered) hoveredBg else normalBg
            g2.fillRoundRect(0, 0, width, height, 12, 12)
            val dash = floatArrayOf(6f, 4f)
            g2.stroke = BasicStroke(1.5f, BasicStroke.CAP_ROUND, BasicStroke.JOIN_ROUND, 0f, dash, 0f)
            g2.color = if (hovered) ACCENT else MUTED
            g2.drawRoundRect(1, 1, width - 3, height - 3, 12, 12)
            g2.dispose()
        }
    }
}
