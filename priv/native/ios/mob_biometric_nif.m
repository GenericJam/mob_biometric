/* mob_biometric_nif — iOS biometric tier-1 plugin NIF (Objective-C).
 *
 * Extracted from mob-core ios/mob_nif.m (nif_biometric_authenticate, lines
 * 2392-2420): LAContext evaluatePolicy with
 * LAPolicyDeviceOwnerAuthenticationWithBiometrics. Self-contained — core's
 * mob_send2 is a private static, so this ships its own (bio_send2). No
 * permission registration: biometric auth uses the device's existing
 * enrollment, there is no runtime permission dialog (Face ID's
 * NSFaceIDUsageDescription plist key is merged from the plugin manifest).
 * Compiled as ObjC (-fobjc-arc) via the plugin objc-NIF path (manifest
 * lang: :objc).
 */
#import <Foundation/Foundation.h>
#import <LocalAuthentication/LocalAuthentication.h>
#include <erl_nif.h>

// Self-contained {atom, atom} send (core's mob_send2 is a private static).
static void bio_send2(const ErlNifPid *pid, const char *a1, const char *a2) {
  ErlNifEnv *e = enif_alloc_env();
  ERL_NIF_TERM msg = enif_make_tuple2(e, enif_make_atom(e, a1), enif_make_atom(e, a2));
  enif_send(NULL, (ErlNifPid *)pid, e, msg);
  enif_free_env(e);
}

// ── Biometric authentication ──────────────────────────────────────────────
// Delivers {:biometric, :success | :failure | :not_available} to the caller.
//
// Outcome mapping is aligned with the Android bridge (platform BiometricPrompt,
// mob_biometric 0.1.3): only an explicit user/system/app cancellation is
// :failure; every other non-success (lockout, repeated mismatch, not
// available / not enrolled, passcode not set, …) is :not_available — matching
// Android's onAuthenticationError, where USER_CANCELED/CANCELED -> :failure and
// everything else -> :not_available.
static const char *bio_outcome_for_error(NSInteger code) {
  switch (code) {
    case LAErrorUserCancel:
    case LAErrorSystemCancel:
    case LAErrorAppCancel:
      return "failure";
    default:
      // LAErrorBiometryLockout / LAErrorAuthenticationFailed /
      // LAErrorBiometryNotAvailable / LAErrorBiometryNotEnrolled /
      // LAErrorPasscodeNotSet / LAErrorUserFallback / … -> not available.
      return "not_available";
  }
}

static ERL_NIF_TERM nif_biometric_authenticate(ErlNifEnv *env, int argc,
                                               const ERL_NIF_TERM argv[]) {
    ErlNifBinary bin;
    if (!enif_inspect_binary(env, argv[0], &bin) &&
        !enif_inspect_iolist_as_binary(env, argv[0], &bin))
        return enif_make_badarg(env);
    NSString *reason = [[NSString alloc] initWithBytes:bin.data
                                                length:bin.size
                                              encoding:NSUTF8StringEncoding];
    ErlNifPid pid;
    enif_self(env, &pid);

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      LAContext *ctx = [[LAContext alloc] init];
      NSError *err = nil;
      if ([ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&err]) {
          [ctx evaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
              localizedReason:reason
                        reply:^(BOOL ok, NSError *e) {
                          bio_send2(&pid, "biometric",
                                    ok ? "success" : bio_outcome_for_error(e.code));
                        }];
      } else {
          bio_send2(&pid, "biometric", "not_available");
      }
    });
    return enif_make_atom(env, "ok");
}

// ── Biometric availability (read-only, no UI) ─────────────────────────────
// canEvaluatePolicy never prompts (the Face ID usage prompt only appears on
// evaluatePolicy). Returns an atom:
//   available         — canEvaluatePolicy succeeded
//   not_enrolled      — LAErrorBiometryNotEnrolled
//   no_hardware       — LAErrorBiometryNotAvailable and biometryType is None
//   unavailable       — LAErrorBiometryNotAvailable with a sensor (e.g. the
//                       user denied this app Face ID), or any other error
//   locked_out        — LAErrorBiometryLockout
//   passcode_not_set  — LAErrorPasscodeNotSet
// biometryType is set by canEvaluatePolicy whatever it returns.
static ERL_NIF_TERM nif_biometric_availability(ErlNifEnv *env, int argc,
                                               const ERL_NIF_TERM argv[]) {
    LAContext *ctx = [[LAContext alloc] init];
    NSError *err = nil;
    if ([ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics error:&err])
        return enif_make_atom(env, "available");
    switch (err.code) {
      case LAErrorBiometryNotEnrolled:
        return enif_make_atom(env, "not_enrolled");
      case LAErrorBiometryNotAvailable:
        return enif_make_atom(env, ctx.biometryType == LABiometryTypeNone ? "no_hardware"
                                                                          : "unavailable");
      case LAErrorBiometryLockout:
        return enif_make_atom(env, "locked_out");
      case LAErrorPasscodeNotSet:
        return enif_make_atom(env, "passcode_not_set");
      default:
        return enif_make_atom(env, "unavailable");
    }
}

// ── Registration ──────────────────────────────────────────────────────────
static ErlNifFunc nif_funcs[] = {
    {"biometric_authenticate", 1, nif_biometric_authenticate, 0},
    {"biometric_availability", 0, nif_biometric_availability, 0},
};

ERL_NIF_INIT(mob_biometric_nif, nif_funcs, NULL, NULL, NULL, NULL)
