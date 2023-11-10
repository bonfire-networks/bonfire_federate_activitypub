defmodule Bonfire.Federate.ActivityPub.Web.FederationEnabledTest do
  use Bonfire.Federate.ActivityPub.DataCase
  use Mneme

  alias Bonfire.Common.Config
  alias Bonfire.Common.Settings

  setup do
    orig = Config.get([:activity_pub, :instance, :federating])

    on_exit(fn ->
      Config.put([:activity_pub, :instance, :federating], orig)
    end)
  end

  test "can disable instance federation entirely" do
    Config.put([:activity_pub, :instance, :federating], false)

    auto_assert false <- Bonfire.Federate.ActivityPub.federating?()
  end

  test "can set instance federation to manual mode" do
    Config.put([:activity_pub, :instance, :federating], nil)

    auto_assert nil <- Bonfire.Federate.ActivityPub.federating?()
  end

  test "can enable instance federation" do
    Config.put([:activity_pub, :instance, :federating], true)

    auto_assert true <- Bonfire.Federate.ActivityPub.federating?()
  end

  test "can disable federation entirely for a user" do
    me = fake_user!()

    me =
      current_user(Settings.put([:activity_pub, :user_federating], false, current_user: me))

    auto_assert false <- Bonfire.Federate.ActivityPub.federating?(me)
  end

  test "can set federation to manual mode for a user" do
    me = fake_user!()

    me =
      current_user(Settings.put([:activity_pub, :user_federating], :manual, current_user: me))

    auto_assert nil <- Bonfire.Federate.ActivityPub.federating?(me)
  end

  test "can enable federation for a user" do
    me = fake_user!()

    me =
      current_user(Settings.put([:activity_pub, :user_federating], true, current_user: me))

    auto_assert true <- Bonfire.Federate.ActivityPub.federating?(me)
  end

  test "cannot enable federation for user when instance is in manual mode" do
    Config.put([:activity_pub, :instance, :federating], nil)

    me = fake_user!()

    me =
      current_user(Settings.put([:activity_pub, :user_federating], true, current_user: me))

    auto_assert nil <- Bonfire.Federate.ActivityPub.federating?(me)
  end

  test "cannot put user in manual mode when instance federation is disabled" do
    Config.put([:activity_pub, :instance, :federating], false)

    me = fake_user!()

    me =
      current_user(Settings.put([:activity_pub, :user_federating], :manual, current_user: me))

    auto_assert false <- Bonfire.Federate.ActivityPub.federating?(me)
  end
end
