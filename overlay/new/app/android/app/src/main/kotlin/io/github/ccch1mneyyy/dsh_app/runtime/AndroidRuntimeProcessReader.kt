package io.github.ccch1mneyyy.dsh_app.runtime

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.NoSuchFileException

/** Shared /proc reader; callers choose their own ownership scope and never log environments. */
internal object AndroidRuntimeProcessReader : RuntimeProcessReader {
    override fun pids(): List<Int> = (File("/proc").listFiles() ?: throw IOException("cannot enumerate /proc"))
        .mapNotNull { it.name.toIntOrNull() }

    override fun uid(pid: Int): Int? = try {
        Os.stat("/proc/$pid").st_uid
    } catch (error: ErrnoException) {
        if (error.errno == OsConstants.ENOENT || error.errno == OsConstants.ESRCH) null else throw error
    } catch (_: NoSuchFileException) { null }

    private fun text(pid: Int, name: String): String = Files.readAllBytes(File("/proc/$pid/$name").toPath()).toString(Charsets.UTF_8)
    override fun stat(pid: Int): String = text(pid, "stat")
    override fun command(pid: Int): String = text(pid, "cmdline")
    override fun environment(pid: Int): String = text(pid, "environ")
    override fun cwd(pid: Int): String = Os.readlink("/proc/$pid/cwd")
}
