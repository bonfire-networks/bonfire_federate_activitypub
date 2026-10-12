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

      # An OPEN, globally visible group, stated rather than defaulted, since this test is about one
      # instance reaching another: `resolve_dims/1` gives a group that states nothing
      # `local:unlisted`, whose actor the peer cannot fetch at all. `type: :group` matters too —
      # without it `init_boundaries/4` takes the TOPIC branch, which applies no membership
      # dimension, so the actor declares the fail-closed `openness: "invite_only"` and the peer
      # mirrors a community nobody there may follow
      group =
        fancy_fake_category!(user,
          type: :group,
          membership: "open",
          visibility: "global",
          participation: "anyone"
        )
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

    # The removal reaches the other instance twice, as the group's `Undo{Announce}` and as the moderator's `Delete` carrying a `summary` (the shape Lemmy acts on), and the two together must take the post out of the group there while leaving the post itself: a group's moderator removes from the group, and has no standing to erase someone's post
    test "a moderator removing a member's post from a group takes it out of the group on a follower's instance, without deleting it",
         context do
      %{moderator: moderator, group: group, post: post, post_url: post_url} =
        member_post_in_followed_group!(context, "a member's post the group will drop")

      assert {:ok, _} =
               Bonfire.Classify.Categories.remove_post_from_group(
                 moderator,
                 group[:category],
                 post
               )

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        assert {:ok, %{pointer_id: remote_post_id}} =
                 ActivityPub.Object.get_cached(ap_id: post_url)

        refute FeedLoader.feed_contains?(:user_activities, remote_post_id,
                 by: group_on_remote,
                 current_user: context[:remote][:user]
               ),
               "the removal takes it out of the group there too"

        assert {:ok, _} = Bonfire.Common.Needles.get(remote_post_id, skip_boundary_check: true),
               "but the post itself is not deleted there"
      end)
    end

    test "a moderator locking a member's post in a group closes it on a follower's instance",
         context do
      %{moderator: moderator, post: post, post_url: post_url} =
        member_post_in_followed_group!(context, "a member's thread the moderator will close")

      remote_post_open? = fn ->
        TestInstanceRepo.apply(fn ->
          {:ok, %{pointer_id: remote_post_id}} = ActivityPub.Object.get_cached(ap_id: post_url)
          remote_post = Bonfire.Common.Needles.get!(remote_post_id, skip_boundary_check: true)
          Bonfire.Boundaries.can?(context[:remote][:user], :reply, remote_post)
        end)
      end

      assert remote_post_open?.(), "control: the thread starts out open there"

      assert {:ok, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: moderator)

      refute remote_post_open?.(), "the lock reaches the follower's instance through the group"
    end

    test "a member editing their post in a group updates it on a follower's instance", context do
      %{member: member, post: post, post_url: post_url} =
        member_post_in_followed_group!(context, "a post before its edit")

      assert {:ok, _} =
               Bonfire.Social.PostContents.edit(member, id(post), %{
                 html_body: "the same post after its edit"
               })

      TestInstanceRepo.apply(fn ->
        {:ok, %{pointer_id: remote_post_id}} = ActivityPub.Object.get_cached(ap_id: post_url)

        remote_post =
          Bonfire.Common.Needles.get!(remote_post_id, skip_boundary_check: true)
          |> repo().maybe_preload(:post_content, force: true)

        assert e(remote_post, :post_content, :html_body, "") =~ "after its edit",
               "the edit reaches the follower's instance through the group"
      end)
    end

    test "a member deleting their post in a group deletes it on a follower's instance", context do
      %{member: member, post: post, post_url: post_url} =
        member_post_in_followed_group!(context, "a post about to be deleted")

      assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: member)

      TestInstanceRepo.apply(fn ->
        refute match?(
                 {:ok, %{pointer_id: id}} when is_binary(id),
                 with(
                   {:ok, %{pointer_id: id} = object} <-
                     ActivityPub.Object.get_cached(ap_id: post_url),
                   {:ok, _} <- Bonfire.Common.Needles.get(id, skip_boundary_check: true),
                   do: {:ok, object}
                 )
               ),
               "the deletion reaches the follower's instance"
      end)
    end

    # A group on this instance, a member of it who is NOT the group's moderator, someone on the other instance following the group, and a post the member published in it, asserted to have reached that follower and to be in the group there: the starting point for what moderators and authors do to such a post
    defp member_post_in_followed_group!(context, html_body) do
      moderator = context[:local][:user]
      member = fake_user!()

      group =
        fancy_fake_category!(moderator,
          type: :group,
          membership: "open",
          visibility: "global",
          participation: "anyone"
        )

      assert {:ok, _} =
               Bonfire.Classify.Categories.join_and_follow_group(member, group[:category])

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        assert {:ok, _} = Follows.follow(context[:remote][:user], group_on_remote)
      end)

      {:ok, post} =
        Posts.publish(
          current_user: member,
          post_attrs: %{post_content: %{html_body: html_body}},
          boundary: "public",
          publish_in: id(group[:category])
        )

      post_url =
        post
        |> repo().maybe_preload([:peered, created: [:peered]])
        |> Bonfire.Common.URIs.canonical_url()

      # a follower's instance files a post in the group because the group announced it
      {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group[:category])
      {:ok, ap_post} = ActivityPub.Object.get_cached(pointer: post)

      assert %{} = ActivityPub.Object.get_existing_announce(group_ap_id, ap_post),
             "control: the group announced the member's post here"

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        # two controls, so a failure says which half is missing: delivery, or filing in the group. Matched as the OBJECT the follower's instance holds rather than by text, which is stored as HTML (an apostrophe becomes an entity)
        assert {:ok, %{pointer_id: remote_post_id}} =
                 ActivityPub.Object.get_cached(ap_id: post_url),
               "control: the member's post reached the follower's instance"

        assert FeedLoader.feed_contains?(:user_activities, remote_post_id,
                 by: group_on_remote,
                 current_user: context[:remote][:user]
               ),
               "control: and is in the group there"
      end)

      %{moderator: moderator, member: member, group: group, post: post, post_url: post_url}
    end
  end
end
