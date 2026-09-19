# AGENTS.md — orientation for AI agents working on mob_biometric

You're in **mob_biometric**, a Mob plugin for on-device biometric authentication. `MobBiometric.authenticate(socket, reason: "...")` shows the OS biometric prompt — Face ID / Touch ID on iOS (`LAContext.evaluatePolicy`), fingerprint on Android (platform `android.hardware.biometrics.BiometricPrompt`) — and delivers `{:biometric, :success | :failure | :not_available}` to the caller's mailbox. Both platforms verified.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — mob's three-repo topology, plugin manifest schema, `Mob.Composite` / `Mob.Sigil`, how to drive a running app from your session, and the cross-cutting pre-empt-failure rules. This file is mob_biometric-specific.

> **Keep this file current.** When you change outcome mapping, touch either native bridge, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_biometric is, in one paragraph

A single-surface plugin: `MobBiometric.authenticate/2` calls the same NIF module name on both platforms (`:mob_biometric_nif`), which shows the OS biometric prompt and delivers the result to the caller PID asynchronously via `handle_info({:biometric, atom}, socket)`. The atom is one of three: `:success` (biometric matched), `:failure` (user or system canceled), `:not_available` (no hardware, none enrolled, lockout, repeated mismatch, or passcode not set). Outcome mapping is aligned across platforms — see the moduledoc and `CHANGELOG.md` 0.1.4 for the LAError-code and BiometricPrompt-error-code translation tables. No runtime permission dialog is shown: the OS biometric prompt *is* the auth flow, using the device's existing enrollment, so the manifest declares no permission capability.

## What mob_biometric is NOT

* **Not an auth plugin.** No passwords, no OTP, no session tokens, no server round-trip. Purely biometric — a proof-of-user gate against the device's own enrollment. If you need a full auth flow, biometric is one factor inside it; this plugin only provides that factor.
* **Not a hardware-capability probe.** `:not_available` is a catch-all delivered for every non-success that isn't an explicit cancel — no hardware, none enrolled, lockout, repeated mismatch, passcode not set. Don't map `:not_available` back to "device lacks a sensor" in host code; the platform doesn't give us that distinction, and inferring it wrong is how the ComponentActivity bug hid for a whole release cycle.
* **Not androidx.biometric.** The Android bridge moved to the platform `android.hardware.biometrics.BiometricPrompt` (API 28+) in 0.1.3. The androidx AAR is retained in `gradle_deps` **only** for the `USE_BIOMETRIC` / `USE_FINGERPRINT` permissions its manifest contributes via merge — the bridge itself doesn't call it.

## Anatomy of the plugin

* `lib/mob_biometric.ex` — the entire public surface: `MobBiometric.authenticate/2`. Moduledoc canonically documents the three-atom result contract and the cross-platform outcome mapping.
* `lib/mob_biometric/demo_screen.ex` — `MobBiometric.DemoScreen`, a ready-to-run authenticate sample declared in the manifest's `:screens`. Pure-Elixir, hot-pushable, kicks the tires the moment the plugin is activated. Delete in a real app.
* `priv/mob_plugin.exs` — plugin manifest. Declares `LocalAuthentication` framework on iOS, no manifest permissions on Android (the AAR contributes them via merge), `androidx.biometric:biometric:1.1.0` as a gradle dep, and merges `NSFaceIDUsageDescription` into the host Info.plist at build time. No permission capability — biometric auth shows no runtime permission dialog.
* `priv/native/ios/mob_biometric_nif.m` — Objective-C NIF wrapping `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)`. Self-contained `bio_send2` (core's `mob_send2` is a private static). Compiled with `-fobjc-arc` via manifest `lang: :objc`.
* `priv/native/jni/mob_biometric_nif.zig` — Android JNI NIF exporting the `nativeRegister` / `nativeDeliverBiometric` symbols the Kotlin bridge calls.
* `priv/native/android/MobBiometricBridge.kt` — Kotlin bridge that constructs the platform `BiometricPrompt` from a `Context`, runs the prompt on the current `Activity`, translates the error code, and calls back into the NIF. One-shot `AtomicBoolean` guards delivery so `onAuthenticationFailed` (non-terminal) doesn't race the terminal callback.

There is no `decisions/` directory yet — the ComponentActivity story lives in `CHANGELOG.md` 0.1.3 and in the moduledoc. Add an ADR here if the bridge changes materially.

## Cross-repo work

**mob (framework):** `MainActivity` is a `ComponentActivity` (Compose host), NOT a `FragmentActivity`. That is a load-bearing invariant for this plugin — see the pre-empt-failure rules below. Plugins that need a Fragment host must adapt (as this one did), never require mob to change host class.

**mob_new (generator template):** `NSFaceIDUsageDescription` is merged into Info.plist by the plugin manifest, so a fresh `mix mob.new` project picks it up automatically once the plugin is added. If mob_new's Info.plist.eex ever grows its own `NSFaceIDUsageDescription`, drop it from this manifest to avoid a merge conflict.

**mob_dev:** `mix mob.deploy --native` regenerates `android/app/src/main/java/io/mob/biometric/MobBiometricBridge.kt` from this repo's `bridge_kt` on every native build. Editing the host app's copy of that file is pointless — it gets clobbered. Point the host at a path-dep of this repo instead.

## Testing

Elixir suite:

```bash
mix deps.get
MIX_ENV=test mix test
```

The suite exercises the plugin manifest end-to-end via `MobDev.Plugin.{Manifest, Validator}` — the real pre-publish validator — plus the module's public surface. What it does NOT cover:

* The `.m` / `.zig` / `.kt` runtime paths. Native code isn't exercised by `mix test`; changes need `mix mob.deploy --native` of a host app (mob_plugin_demo, or your own) and a device check before committing.
* The outcome-mapping tables. They're source-contract tested (the code paths exist and compile), but the actual `LAError` → atom and `BiometricPrompt` error-code → atom translations only fire on device.

Physical-device verification is the real test here. Simulators and emulators lie for biometric: iOS Simulator's "Face ID → Matching Face" menu will not exercise the `LAError` paths, and Android emulators don't have OEM lockout behavior. Kevin has a Moto G Power 5G (2024) and an iPhone SE — use them.

## The pre-empt-failure rules that matter here

1. **Android's `MainActivity` is a `ComponentActivity`, not a `FragmentActivity`.** The androidx.biometric `BiometricPrompt` requires a `FragmentActivity`; a safe cast against a `ComponentActivity` returns `null` and short-circuits to `:not_available` before ever showing a prompt. This bit us for a whole release cycle before 0.1.3 — the plugin returned `:not_available` on every device regardless of enrollment. The bridge now uses the **platform** `android.hardware.biometrics.BiometricPrompt` (API 28+, `Context`-based). Any future Android bridge change must NOT reintroduce a `FragmentActivity` dependency. Mirror the camera bridge's ComponentActivity adaptation pattern.

2. **`:not_available` is a catch-all — do not read intent into it.** Every non-success that isn't an explicit user/system/app cancel maps to `:not_available`: no hardware, none enrolled, lockout, repeated mismatch, passcode not set. On iOS it comes from the `LAError` code; on Android from the `BiometricPrompt` error code. Host code that treats `:not_available` as "device has no sensor" and hides the auth affordance will hide it during lockout too — which is exactly the moment the user is trying to authenticate. Surface the failure honestly; don't collapse the semantics.

3. **Face ID needs `NSFaceIDUsageDescription` in Info.plist — Touch ID doesn't.** The manifest merges the key at build time, so a host that installs the plugin via `mix mob.deploy` gets it automatically. If you edit the manifest, don't remove that plist_keys entry: without it, the first Face ID `evaluatePolicy` is denied by the system and the user sees a permission crash instead of a prompt. Touch ID devices don't need the key, which is why the gap went unnoticed in mob core before extraction.

4. **`onAuthenticationFailed` is non-terminal — don't map it to a result.** Android's `BiometricPrompt` calls `onAuthenticationFailed` on every mismatched attempt (wrong finger, partial print), then eventually calls `onAuthenticationSucceeded` or `onAuthenticationError` as the terminal callback. The bridge uses a one-shot `AtomicBoolean` to deliver exactly one `{:biometric, _}` message; do not weaken that guard. Delivering on `onAuthenticationFailed` would send `:failure` on every finger-wiggle and confuse every caller.

5. **Native (`.m` / `.zig` / `.kt`) changes need `mix mob.deploy --native`, not `mix mob.deploy`.** The plain deploy is BEAM-only and won't rebuild the bridges. `mix test` doesn't exercise the native paths, so a native-only edit that compiles cleanly can still be broken end-to-end. Device-verify before committing.

## Pre-commit + release

`CLAUDE.md` (top-level, deeper detail) is the source of truth. Short version:

```bash
mix test
mix format
mix credo --strict     # includes ExSlop + jump_credo_checks
```

Activate the pre-push hook once per clone or worktree: `git config core.hooksPath .githooks` (or run `mix setup`, which does it). Release = `@version` bump in `mix.exs` on master; `.github/workflows/release.yml` handles tag + GH-release + Hex publish. Do NOT bump versions without explicit permission.
