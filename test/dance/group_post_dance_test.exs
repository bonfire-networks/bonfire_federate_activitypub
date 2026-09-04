if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Federate.ActivityPub.Dance.GroupPostTest do
    use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false
    use Bonfire.Common.Utils

    @moduletag :test_instance

    import Untangle
    import Bonfire.Common.Config, only: [repo: 0]
    import Bonfire.Federate.ActivityPub.SharedDataDanceCase
    import Bonfire.Classify.Simulate

    alias Bonfire.Common.TestInstanceRepo
    alias Bonfire.Federate.ActivityPub.AdapterUtils

    alias Bonfire.Posts
    alias Bonfire.Social.PostContents
    alias Bonfire.Social.FeedLoader
    alias Bonfire.Social.Graph.Follows
    alias Bonfire.Social.FeedActivities

    test "a post in a group on this instance reaches a follower on the other instance, as a boost",
         context do
      user = context[:local][:user]

      group =
        fancy_fake_category!(user)
        |> debug("thegroup")

      id = id(group[:category])

      TestInstanceRepo.apply(fn ->
        Logger.metadata(action: "follow the group")

        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        remote_follower = context[:remote][:user]
        assert {:ok, follow} = Follows.follow(remote_follower, group_on_remote)
      end)

      # back to local

      Logger.metadata(action: "create local post 1")
      attrs = %{post_content: %{html_body: "test content one"}}

      {:ok, post} =
        Posts.publish(
          current_user: user,
          post_attrs: attrs,
          boundary: "public",
          publish_in: id
        )

      # `:user_activities` needs `by:` to say WHOSE activities; `current_user:` only says who is asking
      assert FeedLoader.feed_contains?(:user_activities, post, by: user, current_user: user)

      assert FeedLoader.feed_contains?(:user_activities, post,
               by: group[:category],
               current_user: user
             )

      canonical_url =
        post
        # the guard in `canonical_url/2` is deliberate: locality has to be loaded at the SOURCE
        # rather than fetched per object, and a freshly published post has not loaded it
        |> repo().maybe_preload([:peered, created: [:peered]])
        |> Bonfire.Common.URIs.canonical_url()
        |> info("canonical_url")

      # back to remote
      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        Logger.metadata(action: "check that post 1 was federated to group followers")

        assert activity =
                 FeedLoader.feed_contains?(:user_activities, attrs.post_content.html_body,
                   by: group_on_remote,
                   current_user: context[:remote][:user]
                 )

        # a boost
        assert activity.verb_id == "300ST0R0RANN0VCEANACT1V1TY"
      end)
    end
  end
end
