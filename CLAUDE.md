# mob_biometric — Agent Instructions

**Read [`AGENTS.md`](AGENTS.md) first**, then [`~/code/mob/AGENTS.md`](../mob/AGENTS.md) for the system view. Together they cover the plugin anatomy, the ComponentActivity story, `:not_available` semantics, and the Face ID plist requirement. This file goes deeper on Claude Code-specific workflow detail.

> **Keep AGENTS.md up to date** when you change outcome mapping, touch either native bridge, or hit a new gotcha. Out-of-date guidance there causes wrong decisions downstream — fix it in the same commit, not in a follow-up.

## What this repo is

A Mob plugin extracted from mob core (Wave 2 of the plugin epic). One public surface (`MobBiometric.authenticate/2`), an iOS Objective-C NIF driving `LAContext.evaluatePolicy`, an Android Kotlin bridge over the **platform** `android.hardware.biometrics.BiometricPrompt` (not androidx), and a Zig JNI NIF that bridges the two. Both platforms device-verified.

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
* Do NOT bump versions without explicit permission (per the top of `AGENTS.md`).
* **Never ship without physical-device verification on both platforms.** `mix test` doesn't touch the native paths; simulator and emulator don't exercise the real error codes. Kevin has a Moto G Power 5G (2024) and an iPhone SE — use them.
* The `mob` floor pin (`~> 0.7`) is load-bearing; don't bump if the plugin uses a new mob feature that hasn't shipped yet.
