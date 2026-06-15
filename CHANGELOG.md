# Changelog

All notable changes to **mob_biometric** are documented here.

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [SemVer](https://semver.org/spec/v2.0.0.html).

---

## [0.1.0] - 2026-06-12

Initial release. Biometric authentication (Face ID / Touch ID / fingerprint) for Mob apps.

- `MobBiometric.authenticate/2` with availability reporting via `handle_info`.
- Extracted from mob core in the 0.7.0 plugin-extraction wave.
- Requires `mob ~> 0.7`.
