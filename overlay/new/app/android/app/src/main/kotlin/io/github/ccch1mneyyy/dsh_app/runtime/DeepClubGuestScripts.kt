package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.os.Process as AndroidProcess
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.util.UUID
import java.util.concurrent.TimeUnit

/** Fixed bundled maintenance scripts, run with Node under PRoot before dsh web. */
internal object DeepClubGuestScripts {
    enum class Script(val filename: String, val failure: String) {
        CLEAR_CREDENTIALS("clear-credentials.mjs", "deepclub_credentials_cleanup_failed"),
        PREPARE_PROFILE("prepare-profile.mjs", "deepclub_profile_prepare_failed");

        fun error(exit: Int): String = if (this != PREPARE_PROFILE) failure else when (exit) {
            2 -> "deepclub_profile_invalid"
            3 -> "deepclub_profile_source_conflict"
            4 -> "deepclub_profile_duplicate"
            5 -> "deepclub_profile_write_failed"
            6 -> "deepclub_profile_path_invalid"
            7 -> "deepclub_profile_read_failed"
            else -> failure
        }
    }

    fun run(context: Context, rootfs: File, manifest: RuntimeManifest, operation: Script) {
        val script = File.createTempFile("deepclub-maintenance-", ".mjs", context.cacheDir)
        try {
            context.assets.open("flutter_assets/assets/engine/deepclub/${operation.filename}").use { input ->
                script.outputStream().use { output -> input.copyTo(output) }
            }
            val tmp = File(context.cacheDir, "proot-tmp").apply { mkdirs() }
            val vars = mapOf(
                "{NATIVE_LIB_DIR}" to context.applicationInfo.nativeLibraryDir,
                "{ROOTFS}" to rootfs.canonicalPath,
                "{TMP}" to tmp.canonicalPath,
                "{FILES_DIR}" to context.filesDir.canonicalPath,
            )
            fun expand(text: String) = vars.entries.fold(text) { value, (key, replacement) -> value.replace(key, replacement) }
            val boundary = manifest.launchArgv.indexOf("/usr/bin/env")
            check(boundary > 0) { operation.failure }
            val guestScript = "/deepclub-${operation.filename}"
            val scriptBinding = "${script.canonicalPath}:$guestScript"
            // Separate from the shared rootfs ownership marker: this invocation
            // may only retire its own PRoot and Node tracees.
            val helperMarker = "deepclub-helper:${UUID.randomUUID()}"
            val argv = manifest.launchArgv.take(boundary).map(::expand) + listOf(
                "-b", scriptBinding,
                "/usr/bin/env", "-i", "HOME=/root", "DSH_HOME=/root/.dsh", "NARB_DISABLE_NATIVE_CACHE=1",
                "DSH_GO_RUNTIME_ROOT=$helperMarker",
                "/opt/node/bin/node", guestScript,
            )
            val builder = ProcessBuilder(argv)
                .redirectOutput(File("/dev/null"))
                .redirectError(File("/dev/null"))
            builder.environment().apply {
                clear()
                putAll(manifest.launchEnv.mapValues { expand(it.value) })
                put("DSH_GO_RUNTIME_ROOT", helperMarker)
            }
            val process = builder.start()
            val cleanup = DeepClubHelperCleanup(
                AndroidRuntimeProcessReader, AndroidProcess.myUid(), AndroidProcess.myPid(),
                helperMarker, argv.first(), scriptBinding,
                signal = { pid, signal ->
                    Os.kill(pid, if (signal == DeepClubHelperCleanup.Signal.QUIT) OsConstants.SIGQUIT else OsConstants.SIGKILL)
                },
            )
            var succeeded = false
            try {
                cleanup.capture()
                check(process.waitFor(20, TimeUnit.SECONDS)) { operation.failure }
                check(process.exitValue() == 0) { operation.error(process.exitValue()) }
                succeeded = true
            } finally {
                if (!succeeded) {
                    val reaped = cleanup.terminate()
                    val exited = process.waitFor(5, TimeUnit.SECONDS)
                    check(reaped && exited) { "${operation.failure}: deepclub_helper_cleanup_incomplete" }
                }
            }
        } finally {
            script.delete()
        }
    }
}
