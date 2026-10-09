defmodule MobBiometricTest do
  use ExUnit.Case, async: true

  alias MobBiometric.SelfTest
  alias MobDev.Plugin.{Manifest, Validator}

  @plugin_dir Path.expand("..", __DIR__)

  describe "plugin manifest" do
    setup do
      {:ok, manifest} = Manifest.load(@plugin_dir)
      %{manifest: manifest}
    end

    test "loads and validates clean (round-trips)", %{manifest: m} do
      assert {:ok, ^m} = Manifest.validate(m)
    end

    test "classifies as tier 3 (NIF + a demo screen)", %{manifest: m} do
      # The capability NIF alone is tier 1; the bundled demo screen (a tier-3
      # :screens section) lifts it to 3. tier/1 reports the highest section.
      assert Manifest.tier(m) == 3
    end

    test "passes the full pre-publish validator (paths, NIF modules)",
         %{manifest: m} do
      assert %{errors: []} = Validator.validate_plugin(m, @plugin_dir)
    end

    test "declares the cross-platform NIF pattern: one module, both platforms",
         %{manifest: m} do
      assert [ios, android] = m.nifs
      assert ios.module == :mob_biometric_nif and ios.platform == :ios and ios.lang == :objc
      assert android.module == :mob_biometric_nif and android.platform == :android
      assert android.lang == :zig
    end

    test "registers NO permission capability (biometric uses existing enrollment)",
         %{manifest: m} do
      # No runtime permission dialog exists for biometrics — the OS auth
      # prompt IS the flow — so the manifest must not claim a capability.
      # (Manifest.load returns the raw map; the key is intentionally absent.)
      assert Map.get(m, :permissions, []) == []
    end

    test "Android needs no host manifest permission but ships the androidx.biometric dep",
         %{manifest: m} do
      # USE_BIOMETRIC comes from the androidx.biometric AAR's own manifest
      # (Gradle manifest merge), so the plugin contributes none of its own.
      assert m.android.permissions == []
      assert "androidx.biometric:biometric:1.1.0" in m.android.gradle_deps
    end

    test "iOS declares LocalAuthentication + the NSFaceIDUsageDescription plist key",
         %{manifest: m} do
      assert "LocalAuthentication" in m.ios.frameworks
      assert m.ios.plist_keys["NSFaceIDUsageDescription"] =~ ~r/\S/
    end

    test "every native source dir + Kotlin bridge the manifest references exists",
         %{manifest: m} do
      for %{native_dir: dir} <- m.nifs do
        assert File.dir?(Path.join(@plugin_dir, dir)), "missing #{dir}"
      end

      assert File.exists?(Path.join(@plugin_dir, m.android.bridge_kt))
    end

    test "declares the self-test, which passes the validator without a warning", %{manifest: m} do
      assert m.selftest == MobBiometric.SelfTest
      assert %{errors: [], warnings: warnings} = Validator.validate_plugin(m, @plugin_dir)
      refute Enum.any?(warnings, &(&1 =~ "selftest"))
    end
  end

  describe "MobBiometric.SelfTest" do
    test "on a host with no native library linked it fails, naming the NIF, instead of raising" do
      assert {:fail, reason} = result = SelfTest.run(%{platform: :ios, device: :simulator})
      assert reason =~ "mob_biometric_nif is not linked"
      assert reason =~ "nif_not_loaded"
      assert Mob.Plugin.SelfTest.result?(result)
    end

    test "an available sensor passes" do
      assert SelfTest.classify(:available) == :pass
      assert Mob.Plugin.SelfTest.result?(:pass)
    end

    test "no sensor is a hardware skip" do
      assert SelfTest.classify(:no_hardware) == {:skip, :needs_hardware}
      assert Mob.Plugin.SelfTest.result?({:skip, :needs_hardware})
    end

    test "a sensor the device's state keeps unusable is a skip with a reason, not a pass" do
      for {answer, words} <- [
            not_enrolled: "nothing is enrolled",
            unavailable: "unavailable right now",
            locked_out: "locked out",
            passcode_not_set: "passcode"
          ] do
        assert {:skip, reason} = result = SelfTest.classify(answer)
        assert is_binary(reason) and reason =~ words, "#{answer}: #{inspect(result)}"
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end

    test "a bridge the host never wired up fails" do
      assert {:fail, "Kotlin MobBiometricBridge not registered" <> _} =
               result = SelfTest.classify({:error, :bridge_not_registered})

      assert Mob.Plugin.SelfTest.result?(result)

      assert {:fail, "MobBiometricBridge has no Activity" <> _} =
               result = SelfTest.classify({:error, :no_activity})

      assert Mob.Plugin.SelfTest.result?(result)

      for {reason, words} <- [
            missing_permission: "USE_BIOMETRIC",
            java_exception: "threw",
            missing_face_id_usage_description: "NSFaceIDUsageDescription"
          ] do
        assert {:fail, msg} = result = SelfTest.classify({:error, reason})
        assert msg =~ words
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end

    test "an unexpected answer fails, quoting it" do
      for answer <- [:ok, {:error, 9}, {:error, {:la_error, -1004}}, true] do
        assert {:fail, reason} = result = SelfTest.classify(answer)
        assert reason =~ "biometric_availability/0 returned #{inspect(answer)}"
        assert Mob.Plugin.SelfTest.result?(result)
      end
    end

    test "every answer the Android NIF can build is classified: bare atoms never fail, errors always do" do
      zig_src = File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_biometric_nif.zig"))

      answers =
        for [_, kind, name] <-
              Regex.scan(~r/\d(?:, \d)* => (erts\.atom|errorTuple)\(env, "(\w+)"\)/, zig_src) do
          if kind == "errorTuple", do: {:error, String.to_atom(name)}, else: String.to_atom(name)
        end

      assert :available in answers and {:error, :java_exception} in answers

      for answer <- answers do
        result = SelfTest.classify(answer)
        assert Mob.Plugin.SelfTest.result?(result)
        failed? = match?({:fail, _}, result)
        assert failed? == match?({:error, _}, answer), "#{inspect(answer)} -> #{inspect(result)}"
      end
    end
  end

  describe "NIF stub agreement" do
    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the manifest NIF module is the shipped .erl stub and loads on the host" do
      assert Code.ensure_loaded?(:mob_biometric_nif)
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "every NIF the public API calls is exported by the stub at the right arity" do
      exports = :mob_biometric_nif.module_info(:exports)

      for fa <- [biometric_authenticate: 1, biometric_availability: 0] do
        assert fa in exports, "#{inspect(fa)} missing from mob_biometric_nif exports"
      end
    end

    # Guards the .erl stub / manifest, not app code — VacuousTest can't see that.
    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "host (no native linked) falls back to nif_not_loaded, not a load crash" do
      assert_raise ErlangError, ~r/nif_not_loaded/, fn ->
        :mob_biometric_nif.biometric_authenticate("Authenticate")
      end
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "both native NIF tables and the Kotlin bridge export biometric_availability/0" do
      m_src = File.read!(Path.join(@plugin_dir, "priv/native/ios/mob_biometric_nif.m"))
      zig_src = File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_biometric_nif.zig"))
      kt_src = File.read!(Path.join(@plugin_dir, "priv/native/android/MobBiometricBridge.kt"))

      assert m_src =~
               ~s({"biometric_availability", 0, nif_biometric_availability, ERL_NIF_DIRTY_JOB_IO_BOUND})

      assert zig_src =~ ~s(.name = "biometric_availability", .arity = 0)
      # The zig lookup's "()I" signature must match a static Kotlin method
      # returning a primitive Int (Int? would be Ljava/lang/Integer;).
      assert zig_src =~ ~s|"biometric_availability", "()I"|
      assert kt_src =~ ~r/@JvmStatic\s+fun biometric_availability\(\): Int \{/
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "the Kotlin AVAIL_* codes and the zig switch agree, and 0 never means available" do
      zig_src = File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_biometric_nif.zig"))
      kt_src = File.read!(Path.join(@plugin_dir, "priv/native/android/MobBiometricBridge.kt"))

      kt_codes =
        for [_, name, n] <- Regex.scan(~r/const val AVAIL_(\w+) = (\d+)/, kt_src),
            into: %{},
            do: {String.downcase(name), String.to_integer(n)}

      assert map_size(kt_codes) == 8
      refute 0 in Map.values(kt_codes)

      zig_arms =
        for [_, ns, name] <-
              Regex.scan(~r/(\d(?:, \d)*) => \w+(?:\.atom)?\(env, "(\w+)"\)/, zig_src),
            n <- String.split(ns, ", "),
            into: %{},
            do: {String.to_integer(n), name}

      for {name, n} <- kt_codes do
        assert zig_arms[n] == name,
               "AVAIL_#{String.upcase(name)} = #{n}, zig maps it to #{inspect(zig_arms[n])}"
      end

      assert zig_arms[0] == "java_exception"
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "integration faults in the native availability paths surface as errors, not device states" do
      # These paths only run on a device; pin that they report an error (which
      # the self-test fails) instead of collapsing into a skip-able state.
      zig_src = File.read!(Path.join(@plugin_dir, "priv/native/jni/mob_biometric_nif.zig"))
      kt_src = File.read!(Path.join(@plugin_dir, "priv/native/android/MobBiometricBridge.kt"))
      m_src = File.read!(Path.join(@plugin_dir, "priv/native/ios/mob_biometric_nif.m"))

      # zig: a pending Java exception is checked before the int is trusted.
      assert zig_src =~
               ~r/CallStaticIntMethod.*\n\s*const threw = takePendingException\(jenv\);\n.*\n.*\n\s*if \(threw\) return errorTuple\(env, "java_exception"\);/

      # Kotlin: SecurityException -> MISSING_PERMISSION, unknown canAuthenticate
      # status -> UNEXPECTED_STATUS (both error codes), never UNAVAILABLE.
      assert kt_src =~ ~r/catch \(e: SecurityException\) \{\n.*\n\s*AVAIL_MISSING_PERMISSION/
      assert kt_src =~ ~r/else -> \{\n.*unexpected status.*\n\s*AVAIL_UNEXPECTED_STATUS/

      # iOS: an unknown LAError code or a foreign error domain is an error.
      assert m_src =~ "default: answer = BIO_LA_ERROR;"

      assert m_src =~
               ~r/!\[err\.domain isEqualToString:LAErrorDomain\]\) \{\n\s*answer = BIO_LA_ERROR;/
    end
  end

  describe "public API surface (extraction parity with old Mob.Biometric)" do
    test "exports the full extracted surface" do
      exports = MobBiometric.__info__(:functions)

      for fa <- [authenticate: 2, availability: 0] do
        assert fa in exports, "#{inspect(fa)} missing from MobBiometric"
      end
    end
  end

  describe "Android bridge: platform BiometricPrompt (ComponentActivity-safe)" do
    # Regression guard for the ComponentActivity fix. The Kotlin bridge isn't
    # exercised by `mix test` (native), so assert its source contract instead:
    # it must use the platform android.hardware.biometrics API. androidx's
    # BiometricPrompt requires a FragmentActivity, but mob's MainActivity is a
    # ComponentActivity, so the old `as? FragmentActivity` cast always returned
    # null and delivered :not_available regardless of enrollment.
    setup do
      %{src: File.read!(Path.join(@plugin_dir, "priv/native/android/MobBiometricBridge.kt"))}
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "imports the platform android.hardware.biometrics, not androidx.biometric", %{src: src} do
      assert src =~ "import android.hardware.biometrics.BiometricPrompt"
      refute src =~ "import androidx.biometric"
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "uses the platform Builder, with no androidx FragmentActivity dependency", %{src: src} do
      assert src =~ "BiometricPrompt.Builder("
      refute src =~ "androidx.fragment"
    end
  end

  describe "iOS bridge: LAError outcome mapping aligned with Android" do
    # The iOS NIF (LAContext) and the Android bridge must agree on outcomes:
    # cancel -> :failure, everything else (lockout etc.) -> :not_available. The
    # .m isn't exercised by `mix test`, so assert its source contract.
    setup do
      %{src: File.read!(Path.join(@plugin_dir, "priv/native/ios/mob_biometric_nif.m"))}
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "maps the LAError cancel codes to :failure", %{src: src} do
      for code <- ["LAErrorUserCancel", "LAErrorSystemCancel", "LAErrorAppCancel"] do
        assert src =~ code, "expected the .m to map #{code}"
      end

      assert src =~ ~s(return "failure")
    end

    # credo:disable-for-next-line Jump.CredoChecks.VacuousTest
    test "routes the error code through bio_outcome_for_error, defaulting to :not_available",
         %{src: src} do
      # Replaces the old blanket `ok ? "success" : "failure"` (which made lockout
      # a :failure); the default branch of bio_outcome_for_error is
      # :not_available, matching Android's lockout -> :not_available.
      assert src =~ "bio_outcome_for_error(e.code)"
      assert src =~ ~s(return "not_available")
      refute src =~ ~s(ok ? "success" : "failure")
    end
  end
end
