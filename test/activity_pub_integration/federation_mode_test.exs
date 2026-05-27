defmodule Bonfire.Federate.ActivityPub.FederationModeTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  use Bonfire.Common.Config
  use Bonfire.Common.Settings

  alias Bonfire.Federate.ActivityPub, as: Federation

  describe "federation_mode/1 instance level" do
    test "returns true when instance federation is enabled" do
      Process.put(:federating, true)
      assert Federation.federation_mode() == true
    end

    test "returns false when instance federation is disabled" do
      Process.put(:federating, false)
      assert Federation.federation_mode() == false
    end

    test "returns :allowlist_only when instance is in allowlist-only mode" do
      Process.put(:federating, :allowlist_only)
      assert Federation.federation_mode() == :allowlist_only
    end
  end

  describe "federation_mode/1 user level" do
    test "returns true when user federation is enabled and instance is open" do
      Process.put(:federating, true)
      me = fake_user!()
      me = current_user(Settings.put([:activity_pub, :user_federating], true, current_user: me))
      assert Federation.federation_mode(me) == true
    end

    test "returns false when user disables federation" do
      Process.put(:federating, true)
      me = fake_user!()
      me = current_user(Settings.put([:activity_pub, :user_federating], false, current_user: me))
      assert Federation.federation_mode(me) == false
    end

    test "returns :allowlist_only when user sets allowlist-only mode" do
      Process.put(:federating, true)
      me = fake_user!()

      me =
        current_user(
          Settings.put([:activity_pub, :user_federating], :allowlist_only, current_user: me)
        )

      assert Federation.federation_mode(me) == :allowlist_only
    end

    test "instance :allowlist_only overrides open user setting" do
      Process.put(:federating, :allowlist_only)
      me = fake_user!()
      me = current_user(Settings.put([:activity_pub, :user_federating], true, current_user: me))
      assert Federation.federation_mode(me) == :allowlist_only
    end

    test "instance disabled overrides any user setting" do
      Process.put(:federating, false)
      me = fake_user!()
      me = current_user(Settings.put([:activity_pub, :user_federating], true, current_user: me))
      assert Federation.federation_mode(me) == false
    end
  end

  describe "set_allowlist_only/2" do
    test "sets instance to allowlist-only mode via Process override" do
      Process.put(:federating, :allowlist_only)
      assert Federation.allowlist_only?() == true
      assert Federation.federation_mode() == :allowlist_only
    end

    test "clears instance allowlist-only mode back to open" do
      Process.put(:federating, true)
      assert Federation.allowlist_only?() == false
    end

    test "sets user to allowlist-only mode via Settings" do
      Process.put(:federating, true)
      me = fake_user!()

      me =
        current_user(
          Settings.put([:activity_pub, :user_federating], :allowlist_only, current_user: me)
        )

      assert Federation.allowlist_only?(me) == true
    end
  end

  describe "federation_mode/2 with pre-computed opts" do
    test "short-circuits when opts[:federation_mode] is set" do
      Process.put(:federating, false)
      assert Federation.federation_mode(nil, federation_mode: true) == true
      assert Federation.federation_mode(nil, federation_mode: :allowlist_only) == :allowlist_only
    end
  end

  describe "derived helpers" do
    test "federating? is true when mode is true" do
      Process.put(:federating, true)
      assert Federation.federating?() == true
    end

    test "federating? is true when mode is :allowlist_only" do
      Process.put(:federating, :allowlist_only)
      assert Federation.federating?() == true
    end

    test "federating? is false when mode is false" do
      Process.put(:federating, false)
      assert Federation.federating?() == false
    end

    test "allowlist_only? is true only when mode is :allowlist_only" do
      Process.put(:federating, :allowlist_only)
      assert Federation.allowlist_only?() == true

      Process.put(:federating, true)
      assert Federation.allowlist_only?() == false
    end
  end
end
