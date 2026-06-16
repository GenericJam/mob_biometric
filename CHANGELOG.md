# Changelog

All notable changes to **mob_biometric** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

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
