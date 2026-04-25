package com.hackupc.mobilide

import com.intellij.ui.JBColor
import com.intellij.util.ui.JBUI
import java.awt.*
import java.awt.datatransfer.DataFlavor
import java.awt.datatransfer.Transferable
import java.awt.datatransfer.UnsupportedFlavorException
import java.awt.image.BufferedImage
import javax.swing.*

private const val MAX_DIM = 520

class ImageViewerDialog(
    parent: Component,
    private val filename: String,
    private val image: BufferedImage
) : JDialog(SwingUtilities.getWindowAncestor(parent), filename, ModalityType.MODELESS) {

    init {
        isUndecorated = false
        defaultCloseOperation = DISPOSE_ON_CLOSE

        val scaled = scaledImage()

        val imgLabel = object : JLabel(ImageIcon(scaled)) {
            init {
                border = JBUI.Borders.empty(16, 16, 8, 16)
                horizontalAlignment = SwingConstants.CENTER
            }
        }

        val copyBtn = PillButton("Copy Image", primary = true)
        copyBtn.addActionListener {
            copyToClipboard()
            copyBtn.text = "Copied ✓"
            Timer(1500) { copyBtn.text = "Copy Image" }.also { it.isRepeats = false; it.start() }
        }

        val closeBtn = PillButton("Close")
        closeBtn.addActionListener { dispose() }

        val btnRow = JPanel(FlowLayout(FlowLayout.CENTER, 8, 0)).apply {
            isOpaque = false
            border = JBUI.Borders.empty(4, 16, 16, 16)
            add(copyBtn)
            add(closeBtn)
        }

        val nameLabel = JLabel(filename).apply {
            font = font.deriveFont(Font.BOLD, 11f)
            foreground = MUTED
            horizontalAlignment = SwingConstants.CENTER
            border = JBUI.Borders.empty(0, 16, 8, 16)
        }

        val content = object : JPanel(BorderLayout()) {
            init { isOpaque = true; background = JBColor(Color(252, 252, 254), Color(40, 42, 45)) }
        }
        content.add(imgLabel, BorderLayout.CENTER)
        content.add(nameLabel, BorderLayout.NORTH)
        content.add(btnRow, BorderLayout.SOUTH)

        contentPane = content
        pack()
        setLocationRelativeTo(parent)
        isVisible = true
    }

    private fun scaledImage(): Image {
        val w = image.width; val h = image.height
        if (w <= MAX_DIM && h <= MAX_DIM) return image
        val scale = MAX_DIM.toDouble() / maxOf(w, h)
        return image.getScaledInstance((w * scale).toInt(), (h * scale).toInt(), Image.SCALE_SMOOTH)
    }

    private fun copyToClipboard() {
        val transferable = object : Transferable {
            override fun getTransferDataFlavors() = arrayOf(DataFlavor.imageFlavor)
            override fun isDataFlavorSupported(flavor: DataFlavor) = flavor == DataFlavor.imageFlavor
            override fun getTransferData(flavor: DataFlavor): Any {
                if (flavor != DataFlavor.imageFlavor) throw UnsupportedFlavorException(flavor)
                return image
            }
        }
        Toolkit.getDefaultToolkit().systemClipboard.setContents(transferable, null)
    }
}
