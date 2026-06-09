defmodule Bonfire.Federate.ActivityPub.Dance.PinsTest do
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  import Untangle
  import Bonfire.Common.Config, only: [repo: 0]
  import Bonfire.Federate.ActivityPub.SharedDataDanceCase

  alias Bonfire.Common.TestInstanceRepo
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  alias Bonfire.Posts
  alias Bonfire.Social.Pins
  alias Bonfire.Social.Graph.Follows

  # Pins federate as `Add` to the owner's Mastodon-compatible `featured` collection, addressed to the
  # owner's followers; unpins federate the inverse `Remove`. So a remote follower receives the verb,
  # recognises the target as the owner's featured (via the fetched actor's `featured` property — not
  # URL parsing), and (un)pins the object.
  @tag :test_instance
  test "a pin/unpin federates as an Add/Remove on a follower's instance", context do
    local_user = context[:local][:user]
    local_ap_id = Bonfire.Me.Characters.character_url(local_user) |> info("local_ap_id")
    remote_user = context[:remote][:user]

    body = "pin me across the fediverse"

    # remote follows local, so the pin Add (addressed to the owner's followers) is delivered there
    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("remote follows local"))
      assert {:ok, local_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(local_ap_id)
      assert {:ok, _follow} = Follows.follow(remote_user, local_on_remote)
      assert Follows.following?(remote_user, local_on_remote)
    end)

    Logger.metadata(action: info("local publishes a public post"))

    {:ok, post} =
      Posts.publish(
        current_user: local_user,
        post_attrs: %{post_content: %{html_body: body}},
        boundary: "public"
      )

    Logger.metadata(action: info("local pins the post → federates an Add to featured"))
    assert {:ok, _pin} = Pins.pin(local_user, post)

    TestInstanceRepo.apply(fn ->
      Logger.metadata(action: info("init local_on_remote"))
      assert {:ok, local_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(local_ap_id)

      Logger.metadata(action: info("the federated post is in the follower's feed"))

      assert activity =
               Bonfire.Social.FeedLoader.feed_contains?(:my, body, current_user: remote_user)

      Logger.metadata(
        action: info("the Add was received → the object is pinned by local's actor")
      )

      assert Pins.pinned?(local_on_remote, activity.object)
    end)

    Logger.metadata(action: info("local unpins → federates a Remove from featured"))
    assert Pins.unpin(local_user, post)

    TestInstanceRepo.apply(fn ->
      assert {:ok, local_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(local_ap_id)

      activity = Bonfire.Social.FeedLoader.feed_contains?(:my, body, current_user: remote_user)

      Logger.metadata(action: info("the Remove was received → the object is no longer pinned"))
      refute Pins.pinned?(local_on_remote, activity.object)
    end)
  end
end
