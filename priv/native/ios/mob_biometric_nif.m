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
// evaluatePolicy). Returns:
//   available         — canEvaluatePolicy succeeded
//   not_enrolled      — LAErrorBiometryNotEnrolled
//   no_hardware       — LAErrorBiometryNotAvailable and biometryType is None
//   unavailable       — LAErrorBiometryNotAvailable with a sensor (e.g. the
//                       user denied this app Face ID)
//   locked_out        — LAErrorBiometryLockout
//   passcode_not_set  — LAErrorPasscodeNotSet
//   {error, missing_face_id_usage_description}
//                     — a Face ID device and the host Info.plist lacks
//                       NSFaceIDUsageDescription (the manifest merges it, so
//                       this is a host build bug)
//   {error, {la_error, Code}} — any other LAError / domain: unexpected
// biometryType is set by canEvaluatePolicy whatever it returns. Runs on a
// dirty IO scheduler (canEvaluatePolicy is a synchronous XPC call) inside an
// autorelease pool (scheduler threads never drain the implicit one).
typedef enum {
  BIO_AVAILABLE, BIO_NOT_ENROLLED, BIO_NO_HARDWARE, BIO_UNAVAILABLE,
  BIO_LOCKED_OUT, BIO_PASSCODE_NOT_SET, BIO_MISSING_PLIST_KEY, BIO_LA_ERROR
} bio_availability;

static ERL_NIF_TERM nif_biometric_availability(ErlNifEnv *env, int argc,
                                               const ERL_NIF_TERM argv[]) {
    bio_availability answer;
    NSInteger code = 0;
    @autoreleasepool {
      LAContext *ctx = [[LAContext alloc] init];
      NSError *err = nil;
      BOOL ok = [ctx canEvaluatePolicy:LAPolicyDeviceOwnerAuthenticationWithBiometrics
                                 error:&err];
      code = err.code;
      if (ctx.biometryType == LABiometryTypeFaceID &&
          [[NSBundle mainBundle] objectForInfoDictionaryKey:@"NSFaceIDUsageDescription"] == nil) {
        answer = BIO_MISSING_PLIST_KEY;
      } else if (ok) {
        answer = BIO_AVAILABLE;
      } else if (![err.domain isEqualToString:LAErrorDomain]) {
        answer = BIO_LA_ERROR;
      } else {
        switch (code) {
          case LAErrorBiometryNotEnrolled: answer = BIO_NOT_ENROLLED; break;
          case LAErrorBiometryNotAvailable:
            answer = ctx.biometryType == LABiometryTypeNone ? BIO_NO_HARDWARE : BIO_UNAVAILABLE;
            break;
          case LAErrorBiometryLockout: answer = BIO_LOCKED_OUT; break;
          case LAErrorPasscodeNotSet: answer = BIO_PASSCODE_NOT_SET; break;
          default: answer = BIO_LA_ERROR; break;
        }
      }
    }
    switch (answer) {
      case BIO_AVAILABLE: return enif_make_atom(env, "available");
      case BIO_NOT_ENROLLED: return enif_make_atom(env, "not_enrolled");
      case BIO_NO_HARDWARE: return enif_make_atom(env, "no_hardware");
      case BIO_UNAVAILABLE: return enif_make_atom(env, "unavailable");
      case BIO_LOCKED_OUT: return enif_make_atom(env, "locked_out");
      case BIO_PASSCODE_NOT_SET: return enif_make_atom(env, "passcode_not_set");
      case BIO_MISSING_PLIST_KEY:
        return enif_make_tuple2(env, enif_make_atom(env, "error"),
                                enif_make_atom(env, "missing_face_id_usage_description"));
      case BIO_LA_ERROR:
      default:
        return enif_make_tuple2(
            env, enif_make_atom(env, "error"),
            enif_make_tuple2(env, enif_make_atom(env, "la_error"), enif_make_long(env, (long)code)));
    }
}

// ── Registration ──────────────────────────────────────────────────────────
static ErlNifFunc nif_funcs[] = {
    {"biometric_authenticate", 1, nif_biometric_authenticate, 0},
    {"biometric_availability", 0, nif_biometric_availability, ERL_NIF_DIRTY_JOB_IO_BOUND},
};

ERL_NIF_INIT(mob_biometric_nif, nif_funcs, NULL, NULL, NULL, NULL)
