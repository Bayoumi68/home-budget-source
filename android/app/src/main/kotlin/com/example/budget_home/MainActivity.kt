package com.example.budget_home

import android.app.Activity
import android.content.Intent
import android.content.IntentSender
import com.google.android.gms.auth.api.identity.GetPhoneNumberHintIntentRequest
import com.google.android.gms.auth.api.identity.Identity
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "budget_home/phone_hint"
    private val phoneHintRequestCode = 7001
    private var pendingResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPhoneHint" -> requestPhoneHint(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestPhoneHint(result: MethodChannel.Result) {
        // Only one in-flight request at a time.
        pendingResult?.success(null)
        pendingResult = result

        val request = GetPhoneNumberHintIntentRequest.builder().build()
        Identity.getSignInClient(this)
            .getPhoneNumberHintIntent(request)
            .addOnSuccessListener { pendingIntent ->
                try {
                    startIntentSenderForResult(
                        pendingIntent.intentSender,
                        phoneHintRequestCode,
                        null,
                        0,
                        0,
                        0,
                    )
                } catch (e: IntentSender.SendIntentException) {
                    completePending(null)
                }
            }
            .addOnFailureListener {
                // No SIM number available / Play services unavailable.
                completePending(null)
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != phoneHintRequestCode) return
        if (resultCode == Activity.RESULT_OK && data != null) {
            try {
                val phone = Identity.getSignInClient(this).getPhoneNumberFromIntent(data)
                completePending(phone)
            } catch (e: Exception) {
                completePending(null)
            }
        } else {
            completePending(null)
        }
    }

    private fun completePending(value: String?) {
        pendingResult?.success(value)
        pendingResult = null
    }
}
