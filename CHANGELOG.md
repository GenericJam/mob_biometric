# Changelog

All notable changes to **mob_biometric** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

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
