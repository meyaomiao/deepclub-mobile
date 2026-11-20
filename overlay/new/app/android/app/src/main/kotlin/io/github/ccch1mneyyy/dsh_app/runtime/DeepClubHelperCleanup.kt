package io.github.ccch1mneyyy.dsh_app.runtime

/** One maintenance invocation, not every process using the same rootfs. */
internal class DeepClubHelperCleanup(
    private val reader: RuntimeProcessReader,
    private val uid: Int,
    private val appPid: Int,
    private val marker: String,
    private val prootExecutable: String,
    private val scriptBinding: String,
    private val signal: (Int, Signal) -> Unit,
    private val now: () -> Long = System::nanoTime,
    private val pause: () -> Unit = { Thread.sleep(25) },
) {
    enum class Signal { QUIT, KILL }

    // Captured before signals: tracees can reparent when their PRoot exits.
    private val known = mutableMapOf<Int, String>()

    /** A public-API-only PID discovery on API 26+: parent, exact argv, marker and UID. */
    fun capture() { observe() }

    private fun observe(): Pair<RuntimeProcessSnapshot, List<RuntimeProcessRecord>> {
        val snapshot = RuntimeProcessOwnership.scan(reader, uid, appPid, known.keys)
        snapshot.retired.forEach(known::remove)
        for (record in snapshot.records) {
            if (known[record.pid]?.let { it != record.started } == true) known.remove(record.pid)
            if (record.marker != marker) continue
            // The root PRoot must be our Java child's exact command. Marked Node
            // tracees also remain identifiable if PRoot exited before this scan.
            if (!record.proot || (record.parent == appPid &&
                    record.argv.firstOrNull() == prootExecutable && scriptBinding in record.argv)) {
                known[record.pid] = record.started
            }
        }
        // Empty roots intentionally: sharing a runtime directory or cwd grants
        // no ownership here. Only this invocation's marker/captured descendants do.
        val owned = RuntimeProcessOwnership.owned(snapshot.records, emptySet(), appPid, known)
        owned.forEach { known[it.pid] = it.started }
        val unverified = snapshot.records.filter { it.marker == marker && it.pid !in known }.map { it.pid }
        return snapshot.copy(uncertain = snapshot.uncertain + unverified) to owned
    }

    private fun signalCurrent(record: RuntimeProcessRecord, value: Signal): Boolean = runCatching {
        val current = RuntimeProcessOwnership.stat(reader.stat(record.pid))
        if (current?.second != record.started || reader.uid(record.pid) != uid) false
        else { signal(record.pid, value); true }
        // Failure is not success: the next scan retains a live/unknown identity,
        // and terminate() reports incomplete instead of releasing it silently.
    }.getOrDefault(false)

    fun terminate(): Boolean {
        val deadline = now() + 2_000_000_000L
        val quitSent = mutableSetOf<Pair<Int, String>>()
        while (true) {
            val (snapshot, owned) = observe()
            if (known.isEmpty() && snapshot.observed) return true
            // PRoot must get SIGQUIT before any SIGKILL: its normal quit handler
            // tears down tracees. Already captured tracees are then reaped even if
            // PRoot exits immediately and their parent becomes init.
            for (record in owned.filter { it.proot }) {
                val identity = record.pid to record.started
                val first = identity !in quitSent
                if (signalCurrent(record, if (first) Signal.QUIT else Signal.KILL) && first) quitSent += identity
            }
            owned.filterNot { it.proot }.forEach { signalCurrent(it, Signal.KILL) }
            if (now() >= deadline) return false
            pause()
        }
    }
}
