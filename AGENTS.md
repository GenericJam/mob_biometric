# mob_biometric — Agent Instructions

You're in **mob_biometric**, a Mob plugin for on-device biometric authentication. `MobBiometric.authenticate(socket, reason: "...")` shows the OS biometric prompt — Face ID / Touch ID on iOS (`LAContext.evaluatePolicy`), fingerprint on Android (platform `android.hardware.biometrics.BiometricPrompt`) — and delivers `{:biometric, :success | :failure | :not_available}` to the caller's mailbox. Both platforms verified.

It's a Mob plugin extracted from mob core (Wave 2 of the plugin epic): one public surface (`MobBiometric.authenticate/2`), an iOS Objective-C NIF driving `LAContext.evaluatePolicy`, an Android Kotlin bridge over the **platform** `android.hardware.biometrics.BiometricPrompt` (not androidx), and a Zig JNI NIF that bridges the two.

**Also read [`~/code/mob/AGENTS.md`](../mob/AGENTS.md)** for the system view — mob's three-repo topology, plugin manifest schema, `Mob.Composite` / `Mob.Sigil`, how to drive a running app from your session, and the cross-cutting pre-empt-failure rules. This file is mob_biometric-specific.

> **Keep this file current.** When you change outcome mapping, touch either native bridge, or hit a gotcha that would trip the next agent, fix it here in the same commit — not in a follow-up.

## What mob_biometric is, in one paragraph

A single-surface plugin: `MobBiometric.authenticate/2` calls the same NIF module name on both platforms (`:mob_biometric_nif`), which shows the OS biometric prompt and delivers the result to the caller PID asynchronously via `handle_info({:biometric, atom}, socket)`. The atom is one of three: `:success` (biometric matched), `:failure` (user or system canceled), `:not_available` (no hardware, none enrolled, lockout, repeated mismatch, or passcode not set). Outcome mapping is aligned across platforms — see the moduledoc and `CHANGELOG.md` 0.1.4 for the LAError-code and BiometricPrompt-error-code translation tables. No runtime permission dialog is shown: the OS biometric prompt *is* the auth flow, using the device's existing enrollment, so the manifest declares no permission capability.

## What mob_biometric is NOT

* **Not an auth plugin.** No passwords, no OTP, no session tokens, no server round-trip. Purely biometric — a proof-of-user gate against the device's own enrollment. If you need a full auth flow, biometric is one factor inside it; this plugin only provides that factor.
* **`:not_available` is not a hardware-capability probe.** `:not_available` from `authenticate/2` is a catch-all delivered for every non-success that isn't an explicit cancel — no hardware, none enrolled, lockout, repeated mismatch, passcode not set. Don't map it back to "device lacks a sensor" in host code; inferring it wrong is how the ComponentActivity bug hid for a whole release cycle. The capability probe is `MobBiometric.availability/0` (read-only, no UI): `:available | :not_enrolled | :no_hardware | :unavailable | :locked_out | :passcode_not_set`, or `{:error, reason}` for a miswired host (see its `@doc`).
* **Not androidx.biometric.** The Android bridge moved to the platform `android.hardware.biometrics.BiometricPrompt` (API 28+) in 0.1.3. The androidx AAR is retained in `gradle_deps` **only** for the `USE_BIOMETRIC` / `USE_FINGERPRINT` permissions its manifest contributes via merge — the bridge itself doesn't call it.

## Anatomy of the plugin

* `lib/mob_biometric.ex` — the public surface: `MobBiometric.authenticate/2` (moduledoc canonically documents the three-atom result contract and the cross-platform outcome mapping) and `MobBiometric.availability/0`.
* `lib/mob_biometric/self_test.ex` — `MobBiometric.SelfTest` (`Mob.Plugin.SelfTest`, manifest `selftest:`), run by `mix mob.selftest` / mob_ci. Calls `biometric_availability/0` only — never `authenticate`, which needs a finger or face. `:available` passes; `:no_hardware` is `{:skip, :needs_hardware}`; other device states skip with a reason; an unregistered bridge, a missing Activity or the host stub's `nif_not_loaded` fail.
* `lib/mob_biometric/demo_screen.ex` — `MobBiometric.DemoScreen`, a ready-to-run authenticate sample declared in the manifest's `:screens`. Pure-Elixir, hot-pushable, kicks the tires the moment the plugin is activated. Delete in a real app.
* `priv/mob_plugin.exs` — plugin manifest. Declares `LocalAuthentication` framework on iOS, no manifest permissions on Android (the AAR contributes them via merge), `androidx.biometric:biometric:1.1.0` as a gradle dep, and merges `NSFaceIDUsageDescription` into the host Info.plist at build time. No permission capability — biometric auth shows no runtime permission dialog.
* `priv/native/ios/mob_biometric_nif.m` — Objective-C NIF wrapping `LAContext.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics)` and, for `biometric_availability/0`, `canEvaluatePolicy` (+ `biometryType` to tell no sensor from a denied one). Self-contained `bio_send2` (core's `mob_send2` is a private static). Compiled with `-fobjc-arc` via manifest `lang: :objc`.
* `priv/native/jni/mob_biometric_nif.zig` — Android JNI NIF exporting the `nativeRegister` / `nativeDeliverBiometric` symbols the Kotlin bridge calls. `biometric_availability/0` (dirty IO) calls `MobBiometricBridge.biometric_availability()` (`()I`) and maps its `AVAIL_*` int code to an atom — the Kotlin constants and the zig switch must agree (a test parses both), and code 0 is reserved for "the method threw" so an escaped exception never reads as available. Both NIFs return `{:error, :bridge_not_registered}` when `nativeRegister` never ran or a method-ID lookup failed; `authenticate` then also delivers `{:biometric, :not_available}`.
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

## Worktrees

**Default assumption: work happens in a git worktree.** Kevin runs multiple agents in parallel; each task in its own worktree prevents conflicts.

If a task is assigned to you and worktree usage isn't mentioned, ask:

> "Should I use a worktree for this?"

Yes for anything non-trivial or that touches native code. In-place is fine for a single-file doc edit, one-line config change, or a version bump.

The git stash stack is shared across worktrees — never bare `git stash` / `git stash pop`.

## Pre-commit checklist

Before committing, run all in this order:

```bash
mix test                            # full suite must pass
mix format                          # apply formatting
mix credo --strict                  # whole tree, includes ExSlop + jump_credo_checks
```

Native changes (`.m` / `.zig` / `.kt`) aren't exercised by `mix test` — they need `mix mob.deploy --native` of a host app (mob_plugin_demo, or your own) and a device check before committing.

Pre-push hook (`.githooks/pre-push`) adds format + credo strict + compile on every push and the full suite when `mix.exs` changes (release preflight). Activate once per clone or worktree:

```bash
git config core.hooksPath .githooks
```

Or run `mix setup`, which fetches deps and activates the hooks in one shot.

### Tests are part of the change

New behaviour ships with a test unless the change is small enough that a test would only restate it. The bar is: **would this test fail if the fix were reverted?** Check by reverting it.

For mob_biometric specifically:

* Manifest changes (permissions, plist keys, gradle deps, NIF entries) get an assertion in `test/mob_biometric_test.exs` — the pre-publish validator runs there and will catch drift before a release does.
* Outcome-mapping edits in the ObjC NIF or the Kotlin bridge get a device verification note in the commit message. `mix test` won't fail if you break the mapping — the real gate is the phone.
* Any change to the one-shot `AtomicBoolean` delivery guard needs a device test that fires a mismatch before the terminal callback.

### Adversarial review — before every non-trivial commit

Spawn a subagent, point it at the diff, tell it to find defects rather than approve. Especially for this plugin:

* **ComponentActivity regressions.** Any Android bridge change is one bad cast away from reintroducing the 0.1.2 bug. Ask the reviewer to grep for `as? FragmentActivity` and to check that the platform (not androidx) `BiometricPrompt` is still in use.
* **`:not_available` semantics.** Any outcome-mapping change on either platform: reviewer confirms the three-atom contract still holds and that no code path treats `:not_available` as "device lacks a sensor."
* **Delivery guards.** The Android bridge's `AtomicBoolean` and the iOS NIF's send path both deliver exactly one terminal message per `authenticate/2` call. A change that weakens either causes silent double-deliveries the caller's `handle_info` won't catch.
* **Info.plist / manifest drift.** Face ID needs `NSFaceIDUsageDescription`; the manifest merges it. If someone deletes the plist_keys entry, the first Face ID call denies with no prompt on release builds only.

Skip only for: formatting, a typo, a version bump, a changelog edit.

## Release flow

Canonical process in [`~/code/mob/RELEASE.md`](../mob/RELEASE.md). mob_biometric specifics:

* `@version` in `mix.exs` is the trigger. Push it to master, `.github/workflows/release.yml` handles tag / GH-release / hex-publish, each step idempotent.
* Do NOT bump versions without explicit permission.
* **Never ship without physical-device verification on both platforms.** `mix test` doesn't touch the native paths; simulator and emulator don't exercise the real error codes. Kevin has a Moto G Power 5G (2024) and an iPhone SE — use them.
* The `mob` floor pin (`~> 0.7`) is load-bearing; don't bump if the plugin uses a new mob feature that hasn't shipped yet.
