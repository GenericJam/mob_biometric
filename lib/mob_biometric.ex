defmodule MobBiometric do
  @moduledoc """
  Biometric authentication (Face ID / Touch ID / fingerprint) — a Mob plugin
  (extracted from mob core's `Mob.Biometric` in Wave 2).

  No permission dialog is shown — uses the device's existing biometric
  enrollment, so this plugin registers no permission capability.

      MobBiometric.authenticate(socket, reason: "Confirm payment")

  Result arrives as:

      handle_info({:biometric, :success},        socket)
      handle_info({:biometric, :failure},        socket)
      handle_info({:biometric, :not_available},  socket)

  `:not_available` is returned if the device has no biometric hardware or the
  user has not enrolled any biometrics.

  iOS: `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, ...)`.
  Face ID additionally requires `NSFaceIDUsageDescription` in Info.plist —
  merged from this plugin's manifest at build time.

  Outcomes are consistent across platforms: a successful match is `:success`;
  an explicit user/system cancellation is `:failure`; and anything else (no
  hardware, none enrolled, lockout, repeated mismatch) is `:not_available` — on
  iOS via the `LAError` code, on Android via the `BiometricPrompt` error code.

  Android: the platform `android.hardware.biometrics.BiometricPrompt` (API 28+),
  built from a `Context` so it works with mob's `ComponentActivity` host. (An
  earlier version used androidx.biometric's `BiometricPrompt`, which requires a
  `FragmentActivity`; mob's MainActivity is a `ComponentActivity`, so that cast
  always failed and `:not_available` was delivered regardless of enrollment. The
  platform API needs no FragmentActivity — see MobBiometricBridge.kt.)
  """

  @spec authenticate(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def authenticate(socket, opts \\ []) do
    reason = Keyword.get(opts, :reason, "Authenticate")
    :mob_biometric_nif.biometric_authenticate(reason)
    socket
  end

  @typedoc "What `availability/0` reports about the device's biometrics."
  @type availability ::
          :available
          | :not_enrolled
          | :no_hardware
          | :unavailable
          | :locked_out
          | :passcode_not_set

  @doc """
  Asks the OS whether biometric authentication can run right now, without
  showing any UI. Synchronous; nothing is sent to the mailbox.

    * `:available` — a sensor is present and a biometric is enrolled.
    * `:not_enrolled` — a sensor is present but nothing is enrolled.
    * `:no_hardware` — the device has no biometric sensor.
    * `:unavailable` — a sensor exists but can't be used now (Android: hardware
      busy or a security update is required; iOS: e.g. Face ID denied for the app).
    * `:locked_out` — iOS only: too many failed attempts.
    * `:passcode_not_set` — iOS only: biometrics need a device passcode.

  `{:error, reason}` means the host build is wired wrong, not a device state:

    * Android: `:bridge_not_registered` (the plugin bootstrap never registered
      the Kotlin bridge, or a method lookup failed), `:no_activity` (it never
      handed the bridge an Activity), `:missing_permission` (no
      `USE_BIOMETRIC` / `USE_FINGERPRINT` in the merged manifest),
      `:java_exception` (the bridge threw; logged under tag `MobBiometric`),
      `:no_jni_env`.
    * iOS: `:missing_face_id_usage_description` (a Face ID device whose
      Info.plist lacks the key this plugin's manifest merges) and
      `{:la_error, code}` for an `LAError` code not listed above.

  iOS: `LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`.
  Android: `BiometricManager.canAuthenticate(BIOMETRIC_WEAK)` (API 30+),
  `canAuthenticate()` (API 29), `FingerprintManager` (API 28 — fingerprint
  only, so a face/iris-only device reads `:not_enrolled` / `:no_hardware`).
  Runs on a dirty IO scheduler.

  On a host build with no native library linked this raises `ErlangError`
  (`nif_not_loaded`).
  """
  @spec availability() ::
          availability() | {:error, atom() | {:la_error, integer()} | integer()}
  def availability, do: :mob_biometric_nif.biometric_availability()
end
