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
end
