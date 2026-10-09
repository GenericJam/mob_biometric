defmodule MobBiometric.SelfTest do
  @moduledoc """
  The plugin's on-device proof (`Mob.Plugin.SelfTest`), run by
  `mix mob.selftest` and mob_ci for every activated plugin.

  One synchronous native call, no UI: `:mob_biometric_nif.biometric_availability/0`
  (what `MobBiometric.availability/0` wraps). On iOS it asks
  `LAContext.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`; on
  Android the zig NIF calls `MobBiometricBridge.biometric_availability()`,
  which asks `BiometricManager.canAuthenticate`. Any availability atom proves
  the NIF is linked and, on Android, that the Kotlin bridge is registered and
  holds the Activity — the same bridge state `authenticate/2` needs.
  `authenticate/2` is never called: it shows the OS prompt and needs a finger
  or a face.

    * `:available` passes. The answer came from the OS biometric service
      through the same NIF and bridge the prompt uses; authenticating itself
      would only add a user gesture, which no unattended run can supply.
    * `:no_hardware` is `{:skip, :needs_hardware}` (emulators, simulators and
      sensorless devices), returned only after the native call answered.
    * `:not_enrolled`, `:unavailable`, `:locked_out` and `:passcode_not_set`
      are skips with a reason: the sensor exists but the device's state (no
      enrolment, hardware busy, lockout, no passcode) keeps it unusable, and
      fixing that is the device owner's job.
    * `{:error, :bridge_not_registered}` (Android: `MobBiometricBridge.register()`
      never ran or a method-ID lookup failed), `{:error, :no_activity}` (the
      bootstrap never handed the bridge an Activity) and any other answer
      are failures.
    * The host stub's `nif_not_loaded` is a failure: the NIF is not linked.
  """
  @behaviour Mob.Plugin.SelfTest

  @impl true
  def run(_context) do
    classify(:mob_biometric_nif.biometric_availability())
  rescue
    e in ErlangError ->
      {:fail, "mob_biometric_nif is not linked into this build: #{Exception.message(e)}"}
  end

  @doc false
  # The classification of biometric_availability/0's answer.
  @spec classify(term()) :: Mob.Plugin.SelfTest.result()
  def classify(:available), do: :pass
  def classify(:no_hardware), do: {:skip, :needs_hardware}

  def classify(:not_enrolled),
    do: {:skip, "biometric sensor present but nothing is enrolled on this device"}

  def classify(:unavailable),
    do: {:skip, "biometric sensor present but unavailable right now (busy, update or denied)"}

  def classify(:locked_out),
    do: {:skip, "biometrics locked out after too many failed attempts"}

  def classify(:passcode_not_set),
    do: {:skip, "biometrics need a device passcode, and none is set"}

  def classify({:error, :bridge_not_registered}),
    do:
      {:fail,
       "Kotlin MobBiometricBridge not registered (nativeRegister never ran or a method-ID lookup failed)"}

  def classify({:error, :no_activity}),
    do: {:fail, "MobBiometricBridge has no Activity (MobActivityAware.setActivity never called)"}

  def classify(other),
    do:
      {:fail,
       "biometric_availability/0 returned #{inspect(other)}, expected an availability atom"}
end
