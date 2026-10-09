//! mob_biometric_nif — Android biometric tier-1 ZIG plugin NIF.
//!
//! Extracted from mob-core's `mob_nif.zig`: nif_biometric_authenticate
//! (mob/android/jni/mob_nif.zig:2531) + the {:biometric, atom} delivery,
//! which core routed through the generic mob_deliver_atom2
//! (mob/android/jni/mob_nif.zig:2176 — a 2-tuple of atoms sent to the pid).
//! The Kotlin side is the plugin-owned bridge class
//! `io.mob.biometric.MobBiometricBridge` (androidx.biometric BiometricPrompt);
//! its single inbound delivery thunk is exported directly from this zig file
//! (zig emits the C-ABI Java_ symbol).
//!
//! Build path: compiled via `addZigObject` from `-Dplugin_zig_nifs`, reaching
//! mob-core ERTS / JNI bindings through `@import("erts")` / `@import("jni")`.
//! `get_jenv` + `g_jvm` are mob-core exports linked into the same `.so`.
//!
//! Bridge-class registration: the JVM calls
//! `Java_io_mob_biometric_MobBiometricBridge_nativeRegister(jenv, cls)` at
//! startup (generated MobPluginBootstrap.registerAll -> register()); that
//! thunk caches a global ref to the bridge jclass + the method ID.
const std = @import("std");
const erts = @import("erts");
const jni = @import("jni");

// mob-core exports (linked into the same .so). NOT duplicated.
extern fn get_jenv(attached: *c_int) ?*jni.JNIEnv;
extern var g_jvm: ?*jni.JavaVM;

// ── Plugin-owned bridge-class method-id cache ────────────────────────────
const BioMethods = struct {
    authenticate: jni.JMethodID = null,
    availability: jni.JMethodID = null,
};

var g_bio: BioMethods = .{};
var g_bio_cls: jni.JClass = null;

// ── nativeRegister thunk — cache the bridge jclass + method ids ───────────
// A failed lookup leaves a NoSuchMethodError pending; clear it so register()
// returns normally and the NIF reports {:error, :bridge_not_registered}.
export fn Java_io_mob_biometric_MobBiometricBridge_nativeRegister(jenv: *jni.JNIEnv, cls: jni.JClass) callconv(.c) void {
    g_bio_cls = jni.newGlobalRef(jenv, cls);
    if (g_bio_cls == null) return;
    g_bio.authenticate = jni.getStaticMethodID(jenv, cls, "biometric_authenticate", "(JLjava/lang/String;)V");
    jni.exceptionClear(jenv);
    g_bio.availability = jni.getStaticMethodID(jenv, cls, "biometric_availability", "()I");
    jni.exceptionClear(jenv);
}

// ── Thread-attach + pid round-trip helpers (mirror mob-core / location) ───
inline fn detachIfAttached(attached: c_int) void {
    if (attached != 0) {
        if (g_jvm) |jvm| jni.detachCurrentThread(jvm);
    }
}

inline fn pidToJlong(pid: erts.ErlNifPid) jni.JLong {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return @bitCast(pid.pid);
    }
    return @intCast(pid.pid);
}

inline fn pidFromLong(jpid: jni.JLong) erts.ErlNifPid {
    if (@sizeOf(erts.ERL_NIF_TERM) == @sizeOf(jni.JLong)) {
        return .{ .pid = @bitCast(jpid) };
    }
    const low: u32 = @truncate(@as(u64, @bitCast(jpid)));
    return .{ .pid = low };
}

/// {error, bridge_not_registered}: nativeRegister never ran (MobPluginBootstrap
/// did not call register()) or a method-ID lookup failed.
fn bridgeNotRegistered(env: ?*erts.ErlNifEnv) erts.ERL_NIF_TERM {
    return erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "bridge_not_registered") });
}

/// Call `MobBiometricBridge.<method>(pid_long, arg)` — async; the result lands
/// later via the nativeDeliverBiometric thunk. Returns :ok once dispatched, or
/// {:error, :bridge_not_registered} (the public API ignores the return value).
fn callBridgePidStr(env: ?*erts.ErlNifEnv, method: jni.JMethodID, pid: erts.ErlNifPid, arg: ?[*:0]const u8) erts.ERL_NIF_TERM {
    if (g_bio_cls == null or method == null) return bridgeNotRegistered(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse return erts.atom(env, "error");
    const jarg: jni.JString = if (arg) |a| jni.newStringUTF(jenv, a) else null;
    jenv.*.CallStaticVoidMethod.?(jenv, g_bio_cls, method, pidToJlong(pid), jarg);
    if (jarg != null) jni.deleteLocalRef(jenv, jarg);
    detachIfAttached(attached);
    return erts.ok(env);
}

// ── Inbound delivery thunk — Kotlin's BiometricPrompt callback calls this ─
// Builds {:biometric, :success | :failure | :not_available} and sends it to
// the waiting pid — the SAME 2-tuple-of-atoms shape core delivered via
// mob_deliver_atom2 (mob/android/jni/mob_nif.zig:2176) and iOS delivers via
// mob_send2 (mob/ios/mob_nif.m:2090). Exported directly (zig emits the
// Java_ C-ABI symbol).
export fn Java_io_mob_biometric_MobBiometricBridge_nativeDeliverBiometric(jenv: *jni.JNIEnv, cls: jni.JClass, pid_long: jni.JLong, result: jni.JString) callconv(.c) void {
    _ = cls;
    var pid = pidFromLong(pid_long);
    const env = erts.enif_alloc_env() orelse return;
    defer erts.enif_free_env(env);
    const result_c = jenv.*.GetStringUTFChars.?(jenv, result, null) orelse return;
    defer jenv.*.ReleaseStringUTFChars.?(jenv, result, result_c);
    const msg = erts.makeTuple(env, .{
        erts.atom(env, "biometric"),
        erts.enif_make_atom(env, result_c),
    });
    _ = erts.enif_send(null, &pid, env, msg);
}

// ── NIFs ──────────────────────────────────────────────────────────────────

// Copy a binary/iolist arg into a null-terminated buffer. The bridge call
// (newStringUTF) copies the jstring synchronously, so a stack buffer is fine.
fn binArgZ(env: ?*erts.ErlNifEnv, term: erts.ERL_NIF_TERM, buf: []u8) bool {
    var bin: erts.ErlNifBinary = undefined;
    if (erts.enif_inspect_binary(env, term, &bin) == 0 and
        erts.enif_inspect_iolist_as_binary(env, term, &bin) == 0) return false;
    const n = @min(bin.size, buf.len - 1);
    @memcpy(buf[0..n], bin.data[0..n]);
    buf[n] = 0;
    return true;
}

fn nif_biometric_authenticate(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    // 256-byte truncating copy matches core's defensive buffer
    // (mob/android/jni/mob_nif.zig:2538-2546).
    var reason: [256]u8 = @splat(0);
    if (!binArgZ(env, argv[0], &reason)) return erts.badarg(env);
    var pid: erts.ErlNifPid = undefined;
    _ = erts.enif_self(env, &pid);
    return callBridgePidStr(env, g_bio.authenticate, pid, jni.asCStr(&reason));
}

// biometric_availability/0 — read-only, no UI. Maps the Kotlin bridge's code
// (MobBiometricBridge.biometric_availability) to an atom:
//   0 -> available, 1 -> not_enrolled, 2 -> no_hardware, 3 -> unavailable,
//   4 -> {:error, :no_activity}; bridge never registered ->
//   {:error, :bridge_not_registered}; no JNI env -> {:error, :no_jni_env}.
fn nif_biometric_availability(
    env: ?*erts.ErlNifEnv,
    argc: c_int,
    argv: [*]const erts.ERL_NIF_TERM,
) callconv(.c) erts.ERL_NIF_TERM {
    _ = argc;
    _ = argv;
    if (g_bio_cls == null or g_bio.availability == null) return bridgeNotRegistered(env);
    var attached: c_int = 0;
    const jenv = get_jenv(&attached) orelse
        return erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "no_jni_env") });
    const code = jenv.*.CallStaticIntMethod.?(jenv, g_bio_cls, g_bio.availability);
    jni.exceptionClear(jenv);
    detachIfAttached(attached);
    return switch (code) {
        0 => erts.atom(env, "available"),
        1 => erts.atom(env, "not_enrolled"),
        2 => erts.atom(env, "no_hardware"),
        3 => erts.atom(env, "unavailable"),
        4 => erts.makeTuple(env, .{ erts.atom(env, "error"), erts.atom(env, "no_activity") }),
        else => erts.makeTuple(env, .{ erts.atom(env, "error"), erts.enif_make_int(env, code) }),
    };
}

// ── NIF table + init entry point ─────────────────────────────────────────
fn nifLoad(env: ?*erts.ErlNifEnv, priv: *?*anyopaque, info: erts.ERL_NIF_TERM) callconv(.c) c_int {
    _ = env;
    _ = priv;
    _ = info;
    return 0;
}

const nif_funcs = [_]erts.ErlNifFunc{
    .{ .name = "biometric_authenticate", .arity = 1, .fptr = nif_biometric_authenticate, .flags = 0 },
    .{ .name = "biometric_availability", .arity = 0, .fptr = nif_biometric_availability, .flags = 0 },
};

var nif_entry: erts.ErlNifEntry = .{
    .major = erts.ERL_NIF_MAJOR_VERSION,
    .minor = erts.ERL_NIF_MINOR_VERSION,
    .name = "mob_biometric_nif",
    .num_of_funcs = nif_funcs.len,
    .funcs = &nif_funcs,
    .load = nifLoad,
    .reload = null,
    .upgrade = null,
    .unload = null,
    .vm_variant = erts.ERL_NIF_VM_VARIANT,
    .options = 1,
    .sizeof_ErlNifResourceTypeInit = erts.SIZEOF_ErlNifResourceTypeInit,
    .min_erts = erts.ERL_NIF_MIN_ERTS_VERSION,
};

pub export fn mob_biometric_nif_nif_init() callconv(.c) *erts.ErlNifEntry {
    return &nif_entry;
}
