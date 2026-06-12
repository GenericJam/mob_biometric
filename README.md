# mob_biometric

Biometric authentication (Face ID / Touch ID / fingerprint) for apps built
with [Mob](https://hexdocs.pm/mob) — `Mob.Biometric`, extracted from mob core
as a plugin.

No permission dialog: the OS biometric prompt *is* the auth flow, using the
device's existing enrollment.

## Installation

```elixir
# mix.exs
{:mob_biometric, "~> 0.1"}

# mob.exs
config :mob, :plugins, [:mob_biometric]
```

The plugin manifest merges `NSFaceIDUsageDescription` into the host
Info.plist at build time (Face ID requires it; Touch ID doesn't) and pulls in
`androidx.biometric:biometric:1.1.0` on Android. No manifest permission
needed from the host.

## Usage

```elixir
socket = MobBiometric.authenticate(socket, reason: "Confirm payment")

def handle_info({:biometric, :success}, socket), do: ...
def handle_info({:biometric, :failure}, socket), do: ...
def handle_info({:biometric, :not_available}, socket), do: ...
```

`:not_available` means the device has no biometric hardware or the user has
not enrolled any biometrics.

## Limits

- **Android currently always delivers `:not_available` on mob hosts.**
  androidx.biometric 1.1.0's `BiometricPrompt` requires a `FragmentActivity`
  host; mob's MainActivity is a `ComponentActivity`, so the bridge's safe
  cast fails. This is verbatim parity with mob core's behavior before
  extraction; a fix is tracked.
- iOS works: `LAContext` with `deviceOwnerAuthenticationWithBiometrics`
  (Touch ID and Face ID).

## License

MIT
