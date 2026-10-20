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

  # A moderator's `Add` to the group's `featured`, cc'd to the group, which announces it to its followers (as a Lemmy community relays its mods' features). The follower's instance pins the post into its mirror of the group, not onto the moderator; the `Remove` takes it off again
  @tag :test_instance
  if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
    test "a group pin/unpin reaches a follower's instance, pinned into its mirror of the group",
         context do
      moderator = context[:local][:user]
      remote_user = context[:remote][:user]
      body = "pinned to the top of the group"

      group =
        Bonfire.Classify.Simulate.fancy_fake_category!(moderator,
          type: :group,
          membership: "open",
          visibility: "global",
          participation: "anyone"
        )

      moderator_ap_id = Bonfire.Me.Characters.character_url(moderator)

      TestInstanceRepo.apply(fn ->
        Logger.metadata(action: info("remote follows the group"))
        assert {:ok, group_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])
        assert {:ok, _} = Follows.follow(remote_user, group_on_remote)
      end)

      {:ok, post} =
        Posts.publish(
          current_user: moderator,
          post_attrs: %{post_content: %{html_body: body}},
          boundary: "public",
          publish_in: id(group[:category])
        )

      Logger.metadata(action: info("the moderator pins the post to the top of the group"))
      assert {:ok, _} = Pins.pin(moderator, post, id(group[:category]))

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])
        assert {:ok, moderator_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(moderator_ap_id)

        assert activity =
                 Bonfire.Social.FeedLoader.feed_contains?(:user_activities, body,
                   by: group_on_remote,
                   current_user: remote_user
                 )

        assert Pins.pinned?(id(group_on_remote), activity.object)
        refute Pins.pinned?(id(moderator_on_remote), activity.object)
      end)

      Logger.metadata(action: info("the moderator unpins it"))
      Pins.unpin(moderator, post, id(group[:category]))

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} = AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        activity =
          Bonfire.Social.FeedLoader.feed_contains?(:user_activities, body,
            by: group_on_remote,
            current_user: remote_user
          )

        refute Pins.pinned?(id(group_on_remote), activity.object)
      end)
    end
  end
end
