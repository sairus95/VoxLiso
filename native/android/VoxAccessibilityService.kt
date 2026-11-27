package com.voxliso.voxliso

import android.accessibilityservice.AccessibilityService
import android.content.ComponentName
import android.content.Context
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.DisplayMetrics
import android.view.WindowManager
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo

/**
 * Test « lecture par l'accessibilité » (v1.0.x, 25/11/2026).
 *
 * Les applications protégées (Netflix, Disney+, Prime Video…) apparaissent en
 * noir dans une capture d'écran, mais leurs sous-titres sont souvent dessinés
 * par-dessus la vidéo, par l'application elle-même. Ce service d'accessibilité
 * (le même mécanisme que TalkBack) relève les textes que les autres
 * applications exposent à l'accessibilité, sans toucher à la vidéo, pour savoir
 * si les sous-titres y apparaissent.
 *
 * Toutes les ~300 ms après un changement à l'écran : parcours des fenêtres
 * visibles, textes et descriptions des éléments visibles, position (0..1).
 * Seuls les textes nouveaux par rapport au parcours précédent sont notés
 * (journal de 400 lignes, gardé tant que le service tourne).
 */
class VoxAccessibilityService : AccessibilityService() {

    companion object {
        private const val MAX_LOG = 400
        private const val MAX_NODES = 4000
        private const val SCAN_GAP_MS = 300L

        @Volatile var instance: VoxAccessibilityService? = null

        private val log = ArrayDeque<Map<String, Any>>()

        /** Reçoit chaque texte nouveau (fil principal). */
        var listener: ((Map<String, Any>) -> Unit)? = null

        /** Compteur de parcours (diagnostic). */
        @Volatile var scans = 0L

        /** Paquet de la dernière application vue au premier plan. */
        @Volatile var lastPackage = ""

        /** Chiffres et séparateurs seulement (minuterie du lecteur « 12:34 », « 1/3 »…). */
        private val numberOnly = Regex("^[\\d\\s:/.,%+\\-–]+$")

        fun isEnabled(ctx: Context): Boolean {
            val list = Settings.Secure.getString(
                ctx.contentResolver,
                Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES,
            ) ?: return false
            val me = ComponentName(ctx, VoxAccessibilityService::class.java)
            return list.split(':').any { ComponentName.unflattenFromString(it) == me }
        }

        fun snapshot(): List<Map<String, Any>> = synchronized(log) { log.toList() }

        fun clear() = synchronized(log) { log.clear() }
    }

    private val main = Handler(Looper.getMainLooper())
    private var scheduled = false
    private var lastScan = 0L
    private var previous: Set<String> = emptySet()
    private val scanTask = Runnable {
        scheduled = false
        try {
            scan()
        } catch (_: Exception) {
        }
    }

    override fun onServiceConnected() {
        super.onServiceConnected()
        instance = this
    }

    override fun onDestroy() {
        if (instance === this) instance = null
        main.removeCallbacks(scanTask)
        super.onDestroy()
    }

    override fun onInterrupt() {}

    override fun onAccessibilityEvent(event: AccessibilityEvent?) {
        event ?: return
        val pkg = event.packageName?.toString() ?: ""
        if (pkg == packageName) return
        // Certains lecteurs annoncent les sous-titres au lieu de les afficher en texte.
        if (event.eventType == AccessibilityEvent.TYPE_ANNOUNCEMENT) {
            val text = event.text.joinToString(" ").trim()
            if (text.isNotEmpty()) record(pkg, text, null, "", "", "annonce")
        }
        if (!scheduled) {
            scheduled = true
            val wait = (SCAN_GAP_MS - (SystemClock.uptimeMillis() - lastScan)).coerceAtLeast(0L)
            main.postDelayed(scanTask, wait)
        }
    }

    private fun screenSize(): Pair<Int, Int> {
        val wm = getSystemService(WindowManager::class.java)
        return if (Build.VERSION.SDK_INT >= 30) {
            val b = wm.currentWindowMetrics.bounds
            b.width() to b.height()
        } else {
            val m = DisplayMetrics()
            @Suppress("DEPRECATION")
            wm.defaultDisplay.getRealMetrics(m)
            m.widthPixels to m.heightPixels
        }
    }

    private class Found(
        val pkg: String,
        val text: String,
        val rect: Rect,
        val id: String,
        val cls: String,
        val source: String,
    )

    private fun scan() {
        lastScan = SystemClock.uptimeMillis()
        scans++
        val roots = mutableListOf<AccessibilityNodeInfo>()
        try {
            for (w in windows) {
                if (w.type == AccessibilityWindowInfo.TYPE_ACCESSIBILITY_OVERLAY) continue
                w.root?.let { roots.add(it) }
            }
        } catch (_: Exception) {
        }
        if (roots.isEmpty()) rootInActiveWindow?.let { roots.add(it) }

        val found = LinkedHashMap<String, Found>()
        var budget = MAX_NODES
        fun walk(node: AccessibilityNodeInfo, pkg: String) {
            if (budget-- <= 0) return
            if (!node.isVisibleToUser) return
            val rect = Rect()
            node.getBoundsInScreen(rect)
            val id = node.viewIdResourceName?.substringAfter(":id/") ?: ""
            val cls = node.className?.toString()?.substringAfterLast('.') ?: ""
            val text = node.text?.toString()?.trim().orEmpty()
            val desc = node.contentDescription?.toString()?.trim().orEmpty()
            if (text.isNotEmpty()) found.putIfAbsent("$pkg|$text", Found(pkg, text, rect, id, cls, "texte"))
            if (desc.isNotEmpty() && desc != text) {
                found.putIfAbsent("$pkg|$desc", Found(pkg, desc, rect, id, cls, "description"))
            }
            for (i in 0 until node.childCount) {
                val child = try {
                    node.getChild(i)
                } catch (_: Exception) {
                    null
                } ?: continue
                walk(child, pkg)
                if (Build.VERSION.SDK_INT < 33) {
                    @Suppress("DEPRECATION")
                    child.recycle()
                }
            }
        }
        for (root in roots) {
            val pkg = root.packageName?.toString() ?: ""
            if (pkg != packageName && pkg != "com.android.systemui") {
                lastPackage = pkg
                walk(root, pkg)
            }
        }

        val (w, h) = screenSize()
        for ((key, f) in found) {
            if (key in previous) continue
            if (numberOnly.matches(f.text)) continue
            record(f.pkg, f.text, f.rect, f.id, f.cls, f.source, w, h)
        }
        previous = found.keys.toSet()
    }

    private fun record(
        pkg: String,
        text: String,
        rect: Rect?,
        id: String,
        cls: String,
        source: String,
        w: Int = 1,
        h: Int = 1,
    ) {
        val sw = w.coerceAtLeast(1).toDouble()
        val sh = h.coerceAtLeast(1).toDouble()
        val entry = mutableMapOf<String, Any>(
            "time" to System.currentTimeMillis(),
            "pkg" to pkg,
            "text" to text.take(500),
            "id" to id,
            "cls" to cls,
            "source" to source,
        )
        if (rect != null) {
            entry["l"] = rect.left / sw
            entry["t"] = rect.top / sh
            entry["r"] = rect.right / sw
            entry["b"] = rect.bottom / sh
        }
        synchronized(log) {
            log.addLast(entry)
            while (log.size > MAX_LOG) log.removeFirst()
        }
        main.post { listener?.invoke(entry) }
    }
}
