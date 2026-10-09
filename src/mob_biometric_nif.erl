%% mob_biometric_nif — Erlang NIF module for the biometric tier-1 plugin.
%%
%% iOS: priv/native/ios/mob_biometric_nif.m (Objective-C, LAContext).
%% Android: priv/native/jni/mob_biometric_nif.zig (BiometricPrompt via the
%% io.mob.biometric.MobBiometricBridge Kotlin bridge). Both register this
%% module via ERL_NIF_INIT and are statically linked into the host binary on
%% device. On a host dev build neither is linked, so on_load tolerates the
%% failure and the NIFs fall back to nif_error until the native merge links one.
-module(mob_biometric_nif).
-export([biometric_authenticate/1, biometric_availability/0]).
-on_load(init/0).

init() ->
    case erlang:load_nif("mob_biometric_nif", 0) of
        ok -> ok;
        {error, _} -> ok
    end.

biometric_authenticate(_Reason) ->
    erlang:nif_error(nif_not_loaded).

biometric_availability() ->
    erlang:nif_error(nif_not_loaded).
