%{
  name: :mob_biometric,
  mob_version: "~> 0.6",
  plugin_spec_version: 1,
  description:
    "Biometric authentication (Face ID / Touch ID / fingerprint) — extracted from mob core in Wave 2",
  # A sample screen the host can navigate to by route (auto-listed by a home
  # that enumerates Mob.Plugins.screens/0). Pure-Elixir + hot-pushable; drop it
  # and this entry in a real app that builds its own UI.
  screens: [
    %{module: MobBiometric.DemoScreen, default_route: "/mob_biometric/demo"}
  ],
  nifs: [
    # iOS: Objective-C NIF driving LAContext evaluatePolicy
    # (deviceOwnerAuthenticationWithBiometrics). lang: :objc -> compiled as
    # ObjC (-fobjc-arc); platform: :ios so it isn't pulled into the Android
    # build.
    %{module: :mob_biometric_nif, native_dir: "priv/native/ios", lang: :objc, platform: :ios},
    # Android: zig NIF bridging to androidx.biometric BiometricPrompt via the
    # Kotlin MobBiometricBridge. platform: :android so the iOS build skips it.
    %{module: :mob_biometric_nif, native_dir: "priv/native/jni", lang: :zig, platform: :android}
  ],
  # NO permissions capability entry: biometric auth shows no runtime
  # permission dialog — it uses the device's existing biometric enrollment
  # (the OS-level prompt IS the auth flow), so there is nothing for
  # Mob.Permissions.request/2 to route here.
  android: %{
    bridge_kt: "priv/native/android/MobBiometricBridge.kt",
    bridge_class: "io.mob.biometric.MobBiometricBridge",
    # No manifest permission needed from the host: the mob_new template
    # AndroidManifest.xml.eex declares no USE_BIOMETRIC today — the
    # androidx.biometric AAR's own manifest declares USE_BIOMETRIC /
    # USE_FINGERPRINT and Gradle manifest-merges them into the app.
    permissions: [],
    # Found in the template's app/build.gradle.eex:126 — moves here.
    gradle_deps: ["androidx.biometric:biometric:1.1.0"]
  },
  ios: %{
    frameworks: ["LocalAuthentication"],
    plist_keys: %{
      # NOT present in the template Info.plist.eex today — a latent core gap:
      # Face ID requires NSFaceIDUsageDescription (iOS 11+); without it the
      # first Face ID evaluatePolicy is denied by the system (Touch ID
      # devices don't need it, which is why it went unnoticed). Added here so
      # plugin hosts get it merged at build time.
      "NSFaceIDUsageDescription" =>
        "Face ID is used to authenticate you within the app."
    }
  }
}
