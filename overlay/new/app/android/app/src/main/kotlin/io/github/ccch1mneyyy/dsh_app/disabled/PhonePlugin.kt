package io.github.ccch1mneyyy.dsh_app.disabled

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Compatibility only. The Phase-derived implementation is excluded from this build. */
class PhonePlugin : FlutterPlugin {
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val status = mapOf(
            "ready" to false, "enabled" to false, "available" to false,
            "reason" to "feature_not_available", "a11y" to mapOf("ok" to false),
        )
        methods = MethodChannel(binding.binaryMessenger, "dsh/phone").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "status", "getStatus" -> result.success(status)
                    else -> result.error("feature_not_available", "Phone control is not included in DeepClub Agent.", null)
                }
            }
        }
        events = EventChannel(binding.binaryMessenger, "dsh/phone/events").also {
            it.setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink) { sink.success(status) }
                override fun onCancel(arguments: Any?) {}
            })
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        methods = null
        events = null
    }
}
