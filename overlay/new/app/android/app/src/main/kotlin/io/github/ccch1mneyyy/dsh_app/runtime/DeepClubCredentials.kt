package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS

/** Runs the bundled YAML editor with the engine stopped, never starts dsh web. */
internal object DeepClubCredentials {
    fun clear(context: Context, rootfs: File, manifest: RuntimeManifest) {
        val files = listOf("root/.dsh/.credentials.yaml", "${SafeMode.HOME.removePrefix("/")}/.credentials.yaml")
        if (files.none { Files.exists(File(rootfs, it).toPath(), NOFOLLOW_LINKS) }) return
        DeepClubGuestScripts.run(context, rootfs, manifest, DeepClubGuestScripts.Script.CLEAR_CREDENTIALS)
    }
}
