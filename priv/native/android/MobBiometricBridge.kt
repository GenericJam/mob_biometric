// mob_biometric plugin — Android bridge (platform android.hardware.biometrics).
//
// Uses the PLATFORM BiometricPrompt (android.hardware.biometrics, API 28+),
// which is built from a Context and works with mob's ComponentActivity host.
// The previous androidx.biometric BiometricPrompt requires a FragmentActivity;
// mob's MainActivity is a ComponentActivity (Compose host), so the androidx path
// always failed its `as? FragmentActivity` cast and delivered :not_available
// regardless of enrollment. minSdk is 28, so the platform API covers the whole
// supported range — no FingerprintManager fallback needed. This mirrors how the
// camera bridge adapts to the ComponentActivity host instead of forcing a
// FragmentActivity.
//
// The native thunks (nativeRegister + nativeDeliverBiometric) are exported
// directly from the sibling zig NIF mob_biometric_nif.zig. MobPluginBootstrap
// .registerAll() calls register() at startup and hands it the Activity
// (MobActivityAware). No MobPermissionProvider: biometric auth has no runtime
// permission dialog — it uses the device's existing enrollment.
package io.mob.biometric

import android.app.Activity
import android.content.pm.PackageManager
import android.hardware.biometrics.BiometricManager
import android.hardware.biometrics.BiometricPrompt
import android.hardware.fingerprint.FingerprintManager
import android.os.Build
import android.os.CancellationSignal
import java.lang.ref.WeakReference
import java.util.concurrent.atomic.AtomicBoolean

object MobBiometricBridge : io.mob.plugin.MobActivityAware {
    // biometric_availability() codes; the zig NIF turns them into atoms.
    private const val AVAIL_AVAILABLE = 0
    private const val AVAIL_NOT_ENROLLED = 1
    private const val AVAIL_NO_HARDWARE = 2
    private const val AVAIL_UNAVAILABLE = 3
    private const val AVAIL_NO_ACTIVITY = 4

    private var activityRef: WeakReference<Activity>? = null

    @JvmStatic external fun nativeRegister()

    // result: "success" | "failure" | "not_available" -> {:biometric, atom}
    @JvmStatic external fun nativeDeliverBiometric(pid: Long, result: String)

    @JvmStatic
    fun register() {
        nativeRegister()
    }

    override fun setActivity(activity: Activity) {
        activityRef = WeakReference(activity)
    }

    // Read-only capability check; never shows UI. 0 available, 1 none enrolled,
    // 2 no hardware, 3 hardware unavailable (or security update required),
    // 4 no Activity (the bootstrap never called setActivity).
    @JvmStatic
    fun biometric_availability(): Int {
        val activity = activityRef?.get() ?: return AVAIL_NO_ACTIVITY
        return try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                    val bm = activity.getSystemService(BiometricManager::class.java)
                        ?: return AVAIL_NO_HARDWARE
                    // BIOMETRIC_WEAK (which includes STRONG) is what the
                    // platform BiometricPrompt built below accepts by default.
                    fromCanAuthenticate(bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK))
                }
                Build.VERSION.SDK_INT == Build.VERSION_CODES.Q -> {
                    val bm = activity.getSystemService(BiometricManager::class.java)
                        ?: return AVAIL_NO_HARDWARE
                    @Suppress("DEPRECATION")
                    fromCanAuthenticate(bm.canAuthenticate())
                }
                else -> fingerprintAvailability(activity)
            }
        } catch (e: SecurityException) {
            AVAIL_UNAVAILABLE
        }
    }

    private fun fromCanAuthenticate(code: Int): Int = when (code) {
        BiometricManager.BIOMETRIC_SUCCESS -> AVAIL_AVAILABLE
        BiometricManager.BIOMETRIC_ERROR_NONE_ENROLLED -> AVAIL_NOT_ENROLLED
        BiometricManager.BIOMETRIC_ERROR_NO_HARDWARE -> AVAIL_NO_HARDWARE
        else -> AVAIL_UNAVAILABLE
    }

    // API 28 has no BiometricManager; FingerprintManager is the platform's
    // only enrollment query there (USE_FINGERPRINT comes from the AAR merge).
    @Suppress("DEPRECATION")
    private fun fingerprintAvailability(activity: Activity): Int {
        if (!activity.packageManager.hasSystemFeature(PackageManager.FEATURE_FINGERPRINT)) {
            return AVAIL_NO_HARDWARE
        }
        val fm = activity.getSystemService(FingerprintManager::class.java) ?: return AVAIL_NO_HARDWARE
        return when {
            !fm.isHardwareDetected -> AVAIL_UNAVAILABLE
            !fm.hasEnrolledFingerprints() -> AVAIL_NOT_ENROLLED
            else -> AVAIL_AVAILABLE
        }
    }

    @JvmStatic
    fun biometric_authenticate(pid: Long, reason: String) {
        val activity = activityRef?.get() ?: run {
            nativeDeliverBiometric(pid, "not_available"); return
        }

        // Build + show on the UI thread; results arrive on the main executor.
        activity.runOnUiThread {
            val executor = activity.mainExecutor

            // Exactly one terminal result reaches the BEAM, whichever fires first
            // (success, an error, or the Cancel button).
            val done = AtomicBoolean(false)
            fun deliver(result: String) {
                if (done.compareAndSet(false, true)) nativeDeliverBiometric(pid, result)
            }

            val callback = object : BiometricPrompt.AuthenticationCallback() {
                override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                    deliver("success")
                }

                // onAuthenticationFailed is NON-terminal (a biometric was read but
                // not matched; the prompt stays up to retry) — don't deliver here.

                override fun onAuthenticationError(code: Int, msg: CharSequence) {
                    // User-dismissed -> :failure. No hardware / none enrolled /
                    // unavailable / lockout -> :not_available (no pre-check needed;
                    // the platform reports it here). The Cancel button is also
                    // handled by the negative-button listener below.
                    val outcome = when (code) {
                        BiometricPrompt.BIOMETRIC_ERROR_USER_CANCELED,
                        BiometricPrompt.BIOMETRIC_ERROR_CANCELED -> "failure"
                        else -> "not_available"
                    }
                    deliver(outcome)
                }
            }

            val prompt = BiometricPrompt.Builder(activity)
                .setTitle("Authenticate")
                .setSubtitle(reason)
                // A negative button (or an allowed device-credential authenticator)
                // is mandatory or build() throws.
                .setNegativeButton("Cancel", executor) { _, _ -> deliver("failure") }
                .build()

            prompt.authenticate(CancellationSignal(), executor, callback)
        }
    }
}
