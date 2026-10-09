# Changelog

All notable changes to **mob_biometric** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

### Added
- **`MobBiometric.availability/0`** (MOB-418), a read-only capability query
  that shows no UI: `:available | :not_enrolled | :no_hardware |
  :unavailable | :locked_out | :passcode_not_set`. New NIF
  `biometric_availability/0` on both platforms: iOS
  `LAContext.canEvaluatePolicy` (+ `biometryType`), Android
  `MobBiometricBridge.biometric_availability()` →
  `BiometricManager.canAuthenticate(BIOMETRIC_WEAK)` (API 30+),
  `canAuthenticate()` (API 29), `FingerprintManager` (API 28); runs on a
  dirty IO scheduler. A miswired host answers `{:error, reason}` instead:
  Android `:bridge_not_registered`, `:no_activity`, `:missing_permission`,
  `:java_exception`, `:unexpected_status`, `:no_jni_env`; iOS
  `:missing_face_id_usage_description` (Face ID device, key absent from
  Info.plist) or `{:la_error, code}` for an unexpected `LAError`. A Java
  exception can never read as `:available`.
- **On-device self-test** (MOB-418). `MobBiometric.SelfTest` implements
  `Mob.Plugin.SelfTest` and is declared in the manifest as `selftest:`. It
  calls `biometric_availability/0` (never `authenticate`, which needs a
  finger or a face): `:available` passes, `:no_hardware` is
  `{:skip, :needs_hardware}`, other device states (not enrolled, lockout,
  …) skip with a reason, every `{:error, _}` and an unlinked NIF fail. Run
  it with `mix mob.selftest` from a host app (mob_dev 0.7.17). Requires mob
  0.9.15; `mob_version` in the manifest is now `~> 0.9`.

### Fixed
- **Android: `authenticate/2` with an unregistered bridge** no longer calls
  into a null bridge class; the caller now receives
  `{:biometric, :not_available}` (as on iOS and the no-Activity path) instead
  of nothing. A failed method-ID lookup in `nativeRegister` no longer leaves a
  pending `NoSuchMethodError`, and a Java exception from the bridge call is
  cleared instead of left pending on the scheduler thread.

---

## [0.1.5] - 2026-09-30

### Docs
- **README `## Limits` section retired** (MOB-60). Claimed Android always
  delivered `:not_available`; that was fixed in 0.1.3 (platform
  `BiometricPrompt` on `ComponentActivity`) and 0.1.4 (iOS outcome mapping
  aligned with Android). Renamed to `## Platforms` and updated to describe
  the current per-platform behaviour and outcome mapping.

### Changed
- **Re-signed with plugin envelope v2** (MOB-287). mob_dev 0.7.2+ verifies
  this signature before evaluating the manifest. mob_dev 0.7.0 / 0.7.1 can't
  read v2 signatures and report this release as `invalid signature` —
  upgrade the host app to `{:mob_dev, "~> 0.7.2", only: :dev, runtime: false}`.
  No plugin code changes.

---

## [0.1.4] - 2026-06-24

### Changed
- **iOS outcome mapping aligned with Android.** The iOS NIF now inspects the
  `LAError` code from `evaluatePolicy` instead of mapping every non-success to
  `:failure`: an explicit user/system/app cancellation stays `:failure`, but
  lockout, repeated mismatch, not-available / not-enrolled, and passcode-not-set
  now map to `:not_available` — matching the Android bridge's error-code mapping
  (`USER_CANCELED`/`CANCELED` → `:failure`, else → `:not_available`). Outcomes
  are now identical across platforms. (Source-contract tested; the `.m` runtime
  paths are not exercised by `mix test`.)

---

## [0.1.3] - 2026-06-23

### Fixed
- **Android biometric prompt now actually shows on a mob host.**
  `MobBiometric.authenticate` always delivered `{:biometric, :not_available}`
  on Android regardless of enrollment, because the bridge used
  androidx.biometric's `BiometricPrompt`, whose constructor requires a
  `FragmentActivity`; mob's `MainActivity` is a `ComponentActivity`, so the
  `as? FragmentActivity` cast always returned `null`. The bridge now uses the
  **platform** `android.hardware.biometrics.BiometricPrompt` (API 28+), built
  from a `Context`, so it works with the ComponentActivity host (mirrors the
  camera bridge). Cancel/user-dismiss maps to `:failure`, no-hardware /
  none-enrolled / lockout to `:not_available`; `onAuthenticationFailed` is
  non-terminal; a one-shot guard delivers exactly one terminal result.
  Device-verified on a Moto G power 5G (2024). (#1)

### Notes
- `androidx.biometric:biometric:1.1.0` stays in `gradle_deps` only for the
  `USE_BIOMETRIC` / `USE_FINGERPRINT` permissions its manifest contributes; the
  bridge no longer uses the library. A follow-up may declare the permission in
  the plugin manifest and drop the AAR (needs a device re-verify).

---

## [0.1.2] - 2026-06-16

### Changed
- Signed release: the published package now carries a verified Ed25519
  signature (shared mob first-party key, regenerated in CI on every
  release). Generated apps trust it via `config :mob, :trusted_plugins`,
  so it clears the plugin signature gate without `acknowledge_unsafe_plugins`.

## [0.1.1] - 2026-06-15

### Added
- Bundled `MobBiometric.DemoScreen` — a ready-to-run authenticate sample declared in the manifest's `:screens`, so a generated app can kick the tires on activation. It's pure-Elixir and hot-pushable; the plugin is now tier 3 (NIF + screens). Delete the screen + its `:screens` entry in a real app.

## [0.1.0] - 2026-06-12

Initial release. Biometric authentication (Face ID / Touch ID / fingerprint) for Mob apps.

- `MobBiometric.authenticate/2` with availability reporting via `handle_info`.
- Extracted from mob core in the 0.7.0 plugin-extraction wave.
- Requires `mob ~> 0.7`.
