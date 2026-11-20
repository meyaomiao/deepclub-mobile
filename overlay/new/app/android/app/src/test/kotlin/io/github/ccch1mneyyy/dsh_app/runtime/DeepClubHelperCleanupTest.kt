package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class DeepClubHelperCleanupTest {
    private val uid = 101
    private val appPid = 99
    private val marker = "deepclub-helper:one-invocation"
    private val executable = "/app/lib/libproot.so"
    private val binding = "/app/cache/unique.mjs:/deepclub-prepare-profile.mjs"

    private data class Row(
        val pid: Int,
        val uid: Int,
        val parent: Int,
        val started: String,
        val argv: List<String>,
        val marker: String? = null,
        val state: String = "S",
    )

    private class Reader : RuntimeProcessReader {
        val rows = linkedMapOf<Int, Row>()
        val denied = mutableSetOf<String>()
        val statReads = mutableMapOf<Int, Int>()
        val uidReads = mutableMapOf<Int, Int>()
        var beforeStat: (Int, Int) -> Unit = { _, _ -> }
        var beforeUid: (Int, Int) -> Unit = { _, _ -> }
        private fun readable(key: String) { if (key in denied) throw IOException("controlled read failure") }
        override fun pids(): List<Int> { readable("list"); return rows.keys.toList() }
        override fun uid(pid: Int): Int? {
            val count = (uidReads[pid] ?: 0) + 1
            uidReads[pid] = count
            beforeUid(pid, count)
            readable("$pid/uid")
            return rows[pid]?.uid
        }
        override fun stat(pid: Int): String {
            val count = (statReads[pid] ?: 0) + 1
            statReads[pid] = count
            beforeStat(pid, count)
            readable("$pid/stat")
            val row = rows[pid] ?: throw IOException("exited")
            val fields = MutableList(20) { "0" }
            fields[0] = row.state
            fields[1] = row.parent.toString()
            fields[19] = row.started
            return "$pid (helper process) ${fields.joinToString(" ")}"
        }
        override fun command(pid: Int): String {
            readable("$pid/command")
            return rows.getValue(pid).argv.joinToString("\u0000")
        }
        override fun environment(pid: Int): String {
            readable("$pid/environment")
            return rows.getValue(pid).marker?.let { "DSH_GO_RUNTIME_ROOT=$it\u0000" } ?: ""
        }
        override fun cwd(pid: Int): String = "/shared/runtime/rootfs/root"
    }

    private fun proot(pid: Int = 10, parent: Int = appPid, token: String = marker, bind: String = binding) =
        Row(pid, uid, parent, "start-$pid", listOf(executable, "--rootfs=/shared/runtime/rootfs", "-b", bind), token)

    private fun node(pid: Int = 20, parent: Int = 10, token: String? = marker) =
        Row(pid, uid, parent, "start-$pid", listOf("/opt/node/bin/node", "/deepclub-prepare-profile.mjs"), token)

    private fun scope(reader: Reader, send: (Int, DeepClubHelperCleanup.Signal) -> Unit): DeepClubHelperCleanup {
        var clock = 0L
        return DeepClubHelperCleanup(reader, uid, appPid, marker, executable, binding, send,
            now = { clock }, pause = { clock += 25_000_000L })
    }

    @Test fun quitPrecedesTraceeReapingAndOtherRuntimeInSameDirectoryIsUntouched() {
        val reader = Reader().apply {
            rows[10] = proot()
            rows[20] = node()
            rows[30] = node(30, 20, token = null) // child cleared its environment
            rows[40] = proot(40, token = "/shared/runtime/rootfs", bind = "/other/script")
            rows[50] = node(50, 40, token = "/shared/runtime/rootfs")
        }
        val sent = mutableListOf<Pair<Int, DeepClubHelperCleanup.Signal>>()
        val cleanup = scope(reader) { pid, signal ->
            sent += pid to signal
            reader.rows.remove(pid)
            // PRoot's exit reparents its tracees before the next signal.
            for ((id, row) in reader.rows.toMap()) if (row.parent == pid) reader.rows[id] = row.copy(parent = 1)
        }
        cleanup.capture()
        assertTrue(cleanup.terminate())
        assertEquals(listOf(10 to DeepClubHelperCleanup.Signal.QUIT,
            20 to DeepClubHelperCleanup.Signal.KILL, 30 to DeepClubHelperCleanup.Signal.KILL), sent)
        assertEquals(setOf(40, 50), reader.rows.keys)
    }

    @Test fun prootThatIgnoresQuitGetsKilledOnlyAfterQuitWasDelivered() {
        val reader = Reader().apply { rows[10] = proot(); rows[20] = node() }
        val sent = mutableListOf<Pair<Int, DeepClubHelperCleanup.Signal>>()
        val cleanup = scope(reader) { pid, signal ->
            sent += pid to signal
            if (signal == DeepClubHelperCleanup.Signal.KILL) reader.rows.remove(pid)
        }
        cleanup.capture()
        assertTrue(cleanup.terminate())
        assertEquals(10 to DeepClubHelperCleanup.Signal.QUIT, sent.first())
        assertEquals(10 to DeepClubHelperCleanup.Signal.KILL, sent.last())
        assertTrue(reader.rows.isEmpty())
    }

    @Test fun markedOrphanCanBeReapedEvenWhenProotExitedBeforeCapture() {
        val reader = Reader().apply { rows[20] = node(parent = 1) }
        val sent = mutableListOf<Int>()
        val cleanup = scope(reader) { pid, _ -> sent += pid; reader.rows.remove(pid) }
        assertTrue(cleanup.terminate())
        assertEquals(listOf(20), sent)
    }

    @Test fun capturedTraceeRemainsOwnedAfterReparentingWithoutItsMarker() {
        val reader = Reader().apply { rows[10] = proot(); rows[20] = node(token = null) }
        val sent = mutableListOf<Int>()
        val cleanup = scope(reader) { pid, _ -> sent += pid; reader.rows.remove(pid) }
        cleanup.capture()
        reader.rows.remove(10)
        reader.rows[20] = reader.rows.getValue(20).copy(parent = 1)
        assertTrue(cleanup.terminate())
        assertEquals(listOf(20), sent)
    }

    @Test fun reusedPidIsRetiredInsteadOfKillingTheNewProcess() {
        val reader = Reader().apply { rows[10] = proot() }
        val sent = mutableListOf<Int>()
        val cleanup = scope(reader) { pid, _ -> sent += pid }
        cleanup.capture()
        reader.rows[10] = node(10, appPid, token = "different-job").copy(started = "new-start")
        assertTrue(cleanup.terminate())
        assertTrue(sent.isEmpty())
        assertEquals("new-start", reader.rows.getValue(10).started)
    }

    @Test fun finalSignalGuardRejectsPidReuseAfterTheSnapshot() {
        val reader = Reader().apply {
            rows[10] = proot()
            beforeStat = { pid, count ->
                if (pid == 10 && count == 3) rows[10] = node(10, appPid, "different-job").copy(started = "reused")
            }
        }
        val sent = mutableListOf<Int>()
        val cleanup = scope(reader) { pid, _ -> sent += pid }
        cleanup.capture()
        assertTrue(cleanup.terminate())
        assertTrue(sent.isEmpty())
        assertEquals("reused", reader.rows.getValue(10).started)
    }

    @Test fun finalSignalGuardAlsoChecksTheCurrentUid() {
        val reader = Reader().apply {
            rows[20] = node(parent = 1)
            beforeUid = { pid, count -> if (pid == 20 && count == 3) rows[20] = rows.getValue(20).copy(uid = 202) }
        }
        val sent = mutableListOf<Int>()
        val cleanup = scope(reader) { pid, _ -> sent += pid }
        cleanup.capture()
        assertTrue(cleanup.terminate())
        assertTrue(sent.isEmpty())
        assertEquals(202, reader.rows.getValue(20).uid)
    }

    @Test fun wrongRootParentOrBindingIsNotAuthorityToSendQuit() {
        for (root in listOf(proot(parent = 123), proot(bind = "/unrelated/script"))) {
            val reader = Reader().apply { rows[10] = root }
            val sent = mutableListOf<Int>()
            val cleanup = scope(reader) { pid, _ -> sent += pid }
            assertFalse(cleanup.terminate())
            assertTrue(sent.isEmpty())
        }
    }

    @Test fun incompleteObservationOrFailedSignalsCannotReportSuccessfulCleanup() {
        for (failure in listOf("10/stat", "list", "signal")) {
            val reader = Reader().apply { rows[10] = proot() }
            val sent = mutableListOf<DeepClubHelperCleanup.Signal>()
            val cleanup = scope(reader) { _, signal -> sent += signal; throw IOException("denied") }
            cleanup.capture()
            if (failure != "signal") reader.denied += failure
            assertFalse(cleanup.terminate())
            assertTrue(reader.rows.containsKey(10))
            assertFalse("failed SIGQUIT must never count as delivered", sent.contains(DeepClubHelperCleanup.Signal.KILL))
        }
    }

    @Test fun aConfirmedExitRequiresNoSignals() {
        val reader = Reader().apply { rows[10] = proot(); rows[20] = node() }
        val sent = mutableListOf<Int>()
        val cleanup = scope(reader) { pid, _ -> sent += pid }
        cleanup.capture()
        reader.rows.clear()
        assertTrue(cleanup.terminate())
        assertTrue(sent.isEmpty())
    }
}
