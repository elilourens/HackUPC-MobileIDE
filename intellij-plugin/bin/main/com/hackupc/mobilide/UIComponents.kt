package com.hackupc.mobilide

import com.intellij.ui.JBColor
import com.intellij.util.ui.JBUI
import java.awt.*
import java.awt.event.MouseAdapter
import java.awt.event.MouseEvent
import javax.swing.*

val ACCENT      = JBColor(Color(0, 160, 75),    Color(72, 199, 105))
val CARD_BG     = JBColor(Color(246, 246, 248),  Color(49, 51, 54))
val CARD_BORDER = JBColor(Color(215, 215, 222),  Color(62, 65, 70))
val MUTED       = JBColor(Color(128, 130, 138),  Color(130, 133, 140))

fun Graphics2D.smooth() = setRenderingHint(RenderingHints.KEY_ANTIALIASING, RenderingHints.VALUE_ANTIALIAS_ON)

open class RoundedPanel(
    layout: LayoutManager = BorderLayout(),
    private val radius: Int = 10
) : JPanel(layout) {
    var bg: Color = CARD_BG
    var stroke: Color? = CARD_BORDER

    init { isOpaque = false }

    override fun paintComponent(g: Graphics) {
        val g2 = g.create() as Graphics2D
        g2.smooth()
        g2.color = bg
        g2.fillRoundRect(0, 0, width, height, radius, radius)
        stroke?.let {
            g2.color = it
            g2.drawRoundRect(0, 0, width - 1, height - 1, radius, radius)
        }
        g2.dispose()
    }
}

class PillButton(text: String, private val primary: Boolean = false) : JButton(text) {
    private val normalBg get() = if (primary) ACCENT
        else JBColor(Color(224, 224, 229), Color(68, 71, 76))
    private val hoverBg get() = if (primary) JBColor(Color(0, 138, 64), Color(95, 218, 128))
        else JBColor(Color(206, 206, 212), Color(80, 84, 89))
    private var hovered = false

    init {
        isOpaque = false; isFocusPainted = false
        isBorderPainted = false; isContentAreaFilled = false
        font = font.deriveFont(Font.PLAIN, 12f)
        foreground = if (primary) Color.WHITE
            else JBColor(Color(45, 45, 50), Color(208, 210, 214))
        cursor = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR)
        border = JBUI.Borders.empty(5, 13)
        addMouseListener(object : MouseAdapter() {
            override fun mouseEntered(e: MouseEvent) { hovered = true; repaint() }
            override fun mouseExited(e: MouseEvent) { hovered = false; repaint() }
        })
    }

    override fun paintComponent(g: Graphics) {
        val g2 = g.create() as Graphics2D
        g2.smooth()
        g2.color = if (hovered) hoverBg else normalBg
        g2.fillRoundRect(0, 0, width, height, height, height)
        g2.dispose()
        super.paintComponent(g)
    }
}

class StatusDot : JComponent() {
    var connected = false
    init { preferredSize = Dimension(8, 8); isOpaque = false }
    override fun paintComponent(g: Graphics) {
        val g2 = g.create() as Graphics2D
        g2.smooth()
        g2.color = if (connected) ACCENT else MUTED
        g2.fillOval(0, 0, 8, 8)
        g2.dispose()
    }
}

class UnderlineTabBar(
    tabs: List<String>,
    private val onSwitch: (Int) -> Unit
) : JPanel() {
    private var selected = 0
    private val btns: List<JButton>

    init {
        layout = FlowLayout(FlowLayout.LEFT, 0, 0)
        isOpaque = false
        btns = tabs.mapIndexed { i, name ->
            JButton(name).also { btn ->
                btn.isOpaque = false; btn.isFocusPainted = false
                btn.isBorderPainted = false; btn.isContentAreaFilled = false
                btn.border = JBUI.Borders.empty(8, 14, 10, 14)
                btn.cursor = Cursor.getPredefinedCursor(Cursor.HAND_CURSOR)
                btn.addActionListener { selected = i; refresh(); onSwitch(i) }
                add(btn)
            }
        }
        refresh()
    }

    private fun refresh() {
        btns.forEachIndexed { i, b ->
            b.foreground = if (i == selected) ACCENT else MUTED
            b.font = b.font.deriveFont(if (i == selected) Font.BOLD else Font.PLAIN, 12f)
        }
        repaint()
    }

    override fun paintChildren(g: Graphics) {
        super.paintChildren(g)
        val g2 = g.create() as Graphics2D
        g2.smooth()
        g2.color = CARD_BORDER
        g2.fillRect(0, height - 1, width, 1)
        var x = 0
        btns.forEachIndexed { i, b ->
            if (i == selected) {
                g2.color = ACCENT
                g2.fillRoundRect(x + 10, height - 3, b.width - 20, 3, 3, 3)
            }
            x += b.width
        }
        g2.dispose()
    }
}
