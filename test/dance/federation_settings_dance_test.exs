defmodule Bonfire.Federate.ActivityPub.Dance.FederationSettingsDanceTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase
  use Mneme
  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Posts
  alias Bonfire.Social.Follows

  # setup_all do
  #   orig = Config.get([:activity_pub, :instance, :federating])

  #   on_exit(fn ->
  #     Config.put([:activity_pub, :instance, :federating], orig)
  #   end)
  # end

  @tag :test_instance
  test "can disable instance federation entirely", context do
    ActivityPub.Utils.cache_clear()

    Config.put([:activity_pub, :instance, :federating], false)
    user = context[:local][:user]
    remote_follower = context[:remote][:user]

    auto_assert {:error, "Error trying to connect with ActivityPub remote"} <-
                  AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

    TestInstanceRepo.apply(fn ->
      ActivityPub.Utils.cache_clear()

      auto_assert {:error, "Error trying to connect with ActivityPub remote"} <-
                    AdapterUtils.get_or_fetch_and_create_by_uri(context[:local][:canonical_url])
    end)
  end

  test "can set instance federation to manual mode", context do
    ActivityPub.Utils.cache_clear()

    Config.put([:activity_pub, :instance, :federating], nil)

    user = context[:local][:user]
    remote_follower = context[:remote][:user]

    auto_assert {:ok, %Bonfire.Data.Identity.User{}} <-
                  AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

    TestInstanceRepo.apply(fn ->
      ActivityPub.Utils.cache_clear()

      auto_assert {:ok, %Bonfire.Data.Identity.User{}} <-
                    AdapterUtils.get_or_fetch_and_create_by_uri(context[:local][:canonical_url])
    end)
  end

  test "can disable federation entirely for a user", context do
    ActivityPub.Utils.cache_clear()

    Config.put([:activity_pub, :instance, :federating], true)
    debug(Config.get([:activity_pub, :instance, :federating]), "askjhdas")

    user = context[:local][:user]
    remote_follower = context[:remote][:user]

    user =
      current_user(Settings.put([:activity_pub, :user_federating], false, current_user: user))

    TestInstanceRepo.apply(fn ->
      ActivityPub.Utils.cache_clear()

      auto_assert {:error, "ActivityPub remote replied with HTTP 403"} <-
                    AdapterUtils.get_or_fetch_and_create_by_uri(context[:local][:canonical_url])
    end)
  end

  test "can set federation to manual mode for a user", context do
    ActivityPub.Utils.cache_clear()

    Config.put([:activity_pub, :instance, :federating], true)

    user = context[:local][:user]
    remote_follower = context[:remote][:user]

    user =
      current_user(Settings.put([:activity_pub, :user_federating], :manual, current_user: user))

    TestInstanceRepo.apply(fn ->
      ActivityPub.Utils.cache_clear()

      auto_assert {:ok, %Bonfire.Data.Identity.User{}} <-
                    AdapterUtils.get_or_fetch_and_create_by_uri(context[:local][:canonical_url])
    end)
  end
end
