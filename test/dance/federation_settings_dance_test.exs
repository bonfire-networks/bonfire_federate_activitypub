defmodule Bonfire.Federate.ActivityPub.Dance.FederationSettingsDanceTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase
  use Mneme
  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.Graph.Follows

  setup do
    orig = Config.get([:activity_pub, :instance, :federating])

    repo().query("delete from ap_object  ", [])
    ActivityPub.Utils.cache_clear()

    TestInstanceRepo.apply(fn ->
      repo().query("delete from ap_object  ", [])
      ActivityPub.Utils.cache_clear()
    end)

    on_exit(fn ->
      Config.put([:activity_pub, :instance, :federating], orig)
    end)
  end

  @tag :test_instance
  @tag :mneme
  test "can disable instance federation entirely", context do
    Config.put([:activity_pub, :instance, :federating], false)
    user = context[:local][:user]
    remote_follower = context[:remote][:user]

    # AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])
    auto_assert {:error, "Federation is disabled"} <-
                  ActivityPub.Federator.Fetcher.fetch_object_from_id(
                    context[:remote][:canonical_url]
                  )

    TestInstanceRepo.apply(fn ->
      ActivityPub.Utils.cache_clear()

      auto_assert {:error, "Federation is disabled"} <-
                    ActivityPub.Federator.Fetcher.fetch_object_from_id(
                      context[:local][:canonical_url]
                    )
    end)
  end

  test "can set instance federation to manual mode", context do
    Config.put([:activity_pub, :instance, :federating], nil)

    user = context[:local][:user]
    remote_follower = context[:remote][:user]

    user = current_user(Settings.put([:activity_pub, :user_federating], nil, current_user: user))

    TestInstanceRepo.apply(fn ->
      Settings.put([:activity_pub, :user_federating], nil, current_user: remote_follower)
    end)

    assert {:ok, %ActivityPub.Actor{}} =
             ActivityPub.Federator.Fetcher.fetch_object_from_id(context[:remote][:canonical_url])

    TestInstanceRepo.apply(fn ->
      assert {:ok, %ActivityPub.Actor{}} =
               ActivityPub.Federator.Fetcher.fetch_object_from_id(context[:local][:canonical_url])
    end)
  end

  @tag :mneme
  test "can disable federation entirely for a user", context do
    Config.put([:activity_pub, :instance, :federating], true)
    debug(Config.get([:activity_pub, :instance, :federating]), "askjhdas")

    user = context[:local][:user]
    remote_follower = context[:remote][:user]

    user =
      current_user(Settings.put([:activity_pub, :user_federating], false, current_user: user))

    TestInstanceRepo.apply(fn ->
      auto_assert {:error,
                   "Remote response with HTTP 403: this instance is not currently federating"} <-
                    ActivityPub.Federator.Fetcher.fetch_object_from_id(
                      context[:local][:canonical_url]
                    )

      # AdapterUtils.get_or_fetch_and_create_by_uri(context[:local][:canonical_url])
    end)
  end

  test "can set federation to manual mode for a user", context do
    Config.put([:activity_pub, :instance, :federating], true)

    user = context[:local][:user]
    remote_follower = context[:remote][:user]

    user =
      current_user(Settings.put([:activity_pub, :user_federating], :manual, current_user: user))

    TestInstanceRepo.apply(fn ->
      assert {:ok, %ActivityPub.Actor{}} =
               ActivityPub.Federator.Fetcher.fetch_object_from_id(context[:local][:canonical_url])
    end)
  end
end
