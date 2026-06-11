defmodule MobBiometricTest do
  use ExUnit.Case, async: true

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

    test "classifies as tier 1 (NIF plugin)", %{manifest: m} do
      assert Manifest.tier(m) == 1
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

      for fa <- [biometric_authenticate: 1] do
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
  end

  describe "public API surface (extraction parity with old Mob.Biometric)" do
    test "exports the full extracted surface" do
      exports = MobBiometric.__info__(:functions)

      for fa <- [authenticate: 2] do
        assert fa in exports, "#{inspect(fa)} missing from MobBiometric"
      end
    end
  end
end
