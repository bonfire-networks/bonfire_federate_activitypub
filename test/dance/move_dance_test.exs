defmodule Bonfire.Federate.ActivityPub.Dance.MoveTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Social.Follows
  alias Bonfire.Social.Aliases

  test "simple move profile works between 2 instances",
       context do
    local_origin = context[:local][:user]
    origin_ap_id = Bonfire.Me.Characters.character_url(local_origin)
    info(origin_ap_id, "origin_ap_id")

    target_ap_id = context[:remote][:canonical_url]

    info(target_ap_id, "target_ap_id")

    Logger.metadata(action: info("init target_on_local"))
    assert {:ok, target_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(target_ap_id)

    Logger.metadata(action: info("attempt the move illegaly"))
    assert {:error, :not_in_also_known_as} = Aliases.move(local_origin, target_on_local)

    remote_target = context[:remote][:user]

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("init origin_on_remote"))

      assert {:ok, origin_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(origin_ap_id)

      assert ulid(origin_on_remote) != ulid(local_origin)
      assert ulid(remote_target) != ulid(target_on_local)

      Logger.metadata(action: info("add local actor as an alias of remote user"))

      Aliases.add(remote_target, origin_on_remote)
    end)

    Logger.metadata(action: info("re-attempt the move"))
    assert {:ok, move} = Aliases.move(local_origin, target_on_local)

    # no longer needed:
    # Logger.metadata(action: info("re-fetch target_on_local"))
    # assert {:ok, refetched} = ActivityPub.Federator.Fetcher.fetch_fresh_object_from_id(target_ap_id)
    # info(refetched, "refetched")
    # target_on_local = refetched.pointer

    # Logger.metadata(action: info("re-attempt the move, part 2"))
    # assert {:ok, move} = Aliases.move(local_origin, target_on_local)
    # info(move, "the move")
  end

  test "move profile & follows works between 2 instances",
       context do
    # swap to avoid conflict with the other test
    follow_context = context

    context = [
      local: a_fake_user!("Local"),
      remote: fake_remote!()
    ]

    local_follower = follow_context[:local][:user]
    follower_ap_id = Bonfire.Me.Characters.character_url(local_follower)

    info(follower_ap_id, "follower_ap_id")
    follower2_ap_id = follow_context[:remote][:canonical_url]
    info(follower2_ap_id, "follower2_ap_id")

    Logger.metadata(action: info("init follower2_on_local"))

    assert {:ok, follower2_on_local} =
             AdapterUtils.get_or_fetch_and_create_by_uri(follower2_ap_id)

    target_ap_id = context[:remote][:canonical_url]
    local_origin = context[:local][:user]

    info(target_ap_id, "target_ap_id")

    Logger.metadata(action: info("init target_on_local"))
    assert {:ok, target_on_local} = AdapterUtils.get_or_fetch_and_create_by_uri(target_ap_id)

    Logger.metadata(action: info("do the 1st follow"))
    assert {:ok, follow} = Follows.follow(local_follower, local_origin)
    refute Follows.requested?(local_follower, local_origin)
    assert Follows.following?(local_follower, local_origin)

    origin_ap_id = Bonfire.Me.Characters.character_url(local_origin)
    info(origin_ap_id, "origin_ap_id")

    Logger.metadata(action: info("attempt the move illegaly"))
    assert {:error, :not_in_also_known_as} = Aliases.move(local_origin, target_on_local)

    remote_target = context[:remote][:user]
    remote_follower2 = context[:remote][:user]

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("init origin_on_remote"))

      assert {:ok, origin_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(origin_ap_id)

      Logger.metadata(action: info("init followers_on_remote"))

      assert {:ok, follower_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

      assert {:ok, follower2_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(follower2_ap_id)

      assert ulid(origin_on_remote) != ulid(local_origin)
      assert ulid(remote_target) != ulid(target_on_local)

      Logger.metadata(action: info("add local actor as an alias of remote user"))

      Aliases.add(remote_target, origin_on_remote)

      Logger.metadata(action: info("do 2nd follow"))
      assert {:ok, follow2} = Follows.follow(follower2_on_remote, origin_on_remote)

      Logger.metadata(action: info("check follow worked on remote"))

      refute Follows.requested?(follower2_on_remote, origin_on_remote)
      assert Follows.following?(follower2_on_remote, origin_on_remote)
    end)

    Logger.metadata(action: info("re-attempt the move"))
    assert {:ok, move} = Aliases.move(local_origin, target_on_local)
    info(move, "the move")

    Logger.metadata(action: info("check move of follows worked on local"))
    refute Follows.following?(local_follower, local_origin)
    assert Follows.following?(local_follower, target_on_local)

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("init origin_on_remote"))

      assert {:ok, origin_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(origin_ap_id)

      Logger.metadata(action: info("init followers_on_remote"))

      assert {:ok, follower_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(follower_ap_id)

      assert {:ok, follower2_on_remote} =
               AdapterUtils.get_or_fetch_and_create_by_uri(follower2_ap_id)

      Logger.metadata(action: info("check move of follows worked on remote"))

      refute Follows.following?(follower2_on_remote, origin_on_remote)
      assert Follows.following?(follower2_on_remote, remote_target)
    end)
  end
end
