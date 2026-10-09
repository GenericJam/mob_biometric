// mob_biometric plugin — Android bridge (platform android.hardware.biometrics).
//
// Uses the PLATFORM BiometricPrompt (android.hardware.biometrics, API 28+),
// which is built from a Context and works with mob's ComponentActivity host.
// The previous androidx.biometric BiometricPrompt requires a FragmentActivity;
// mob's MainActivity is a ComponentActivity (Compose host), so the androidx path
// always failed its `as? FragmentActivity` cast and delivered :not_available
// regardless of enrollment. minSdk is 28, so the platform API covers the whole
// supported range for the prompt. (The read-only biometric_availability() query
// falls back to FingerprintManager on API 28, which has no BiometricManager.)
// This mirrors how the camera bridge adapts to the ComponentActivity host
// instead of forcing a FragmentActivity.
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
    // biometric_availability() codes; the zig NIF turns each into the atom its
    // name spells (AVAIL_NOT_ENROLLED -> :not_enrolled; the last three into
    // {:error, atom}). 0 is deliberately unused: it is what ART returns from
    // CallStaticIntMethod when the method throws, so an exception that escaped
    // can never read as "available".
    private const val AVAIL_AVAILABLE = 1
    private const val AVAIL_NOT_ENROLLED = 2
    private const val AVAIL_NO_HARDWARE = 3
    private const val AVAIL_UNAVAILABLE = 4
    private const val AVAIL_NO_ACTIVITY = 5
    private const val AVAIL_MISSING_PERMISSION = 6
    private const val AVAIL_JAVA_EXCEPTION = 7

    // Written on the main thread (setActivity), read on BEAM scheduler threads.
    @Volatile private var activityRef: WeakReference<Activity>? = null

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

    // Read-only capability check; never shows UI. Codes above; NO_ACTIVITY means
    // the bootstrap never called setActivity, MISSING_PERMISSION that the host
    // manifest lacks USE_BIOMETRIC / USE_FINGERPRINT (normally merged from the
    // androidx.biometric AAR). On API 28 only fingerprint is visible, so an OEM
    // face/iris-only device reports not enrolled / no hardware there.
    @JvmStatic
    fun biometric_availability(): Int {
        val activity = activityRef?.get() ?: return AVAIL_NO_ACTIVITY
        return try {
            when {
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R -> {
                    val bm = activity.getSystemService(BiometricManager::class.java)
                        ?: return AVAIL_UNAVAILABLE
                    // BIOMETRIC_WEAK (which includes STRONG) is what the
                    // platform BiometricPrompt built below accepts by default.
                    fromCanAuthenticate(bm.canAuthenticate(BiometricManager.Authenticators.BIOMETRIC_WEAK))
                }
                Build.VERSION.SDK_INT == Build.VERSION_CODES.Q -> {
                    val bm = activity.getSystemService(BiometricManager::class.java)
                        ?: return AVAIL_UNAVAILABLE
                    @Suppress("DEPRECATION")
                    fromCanAuthenticate(bm.canAuthenticate())
                }
                else -> fingerprintAvailability(activity)
            }
        } catch (e: SecurityException) {
            android.util.Log.w("MobBiometric", "biometric_availability: missing permission", e)
            AVAIL_MISSING_PERMISSION
        } catch (t: Throwable) {
            android.util.Log.w("MobBiometric", "biometric_availability threw", t)
            AVAIL_JAVA_EXCEPTION
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
        val fm = activity.getSystemService(FingerprintManager::class.java) ?: return AVAIL_UNAVAILABLE
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
