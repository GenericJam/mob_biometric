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

  Android: `BiometricPrompt` (androidx.biometric). NOTE: androidx.biometric
  1.1.0's `BiometricPrompt` requires a `FragmentActivity` host; mob's
  MainActivity is a `ComponentActivity`, so on today's hosts the bridge's
  safe cast fails and `:not_available` is delivered (verbatim parity with
  core's current behavior — see MobBiometricBridge.kt).
  """

  @spec authenticate(Mob.Socket.t(), keyword()) :: Mob.Socket.t()
  def authenticate(socket, opts \\ []) do
    reason = Keyword.get(opts, :reason, "Authenticate")
    :mob_biometric_nif.biometric_authenticate(reason)
    socket
  end
end
