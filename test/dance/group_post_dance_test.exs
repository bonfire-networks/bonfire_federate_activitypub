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

    # A ban the moderator chooses to federate (`also_unfollow_and_notify`) goes out as Lemmy's ban, the moderator's `Block` with `target` the group, relayed by the group, so the follower's instance applies it to its copy of the group: the banned person, there, can no longer take part in it, and lifting the ban here lifts it there
    test "a moderator banning someone from a group keeps them out of it on their own instance, and unbanning lets them back in",
         context do
      %{moderator: moderator, group: group, post_url: post_url} =
        member_post_in_followed_group!(context, "a post the banned person can't reply to")

      remote_can_reply? = fn ->
        TestInstanceRepo.apply(fn ->
          {:ok, %{pointer_id: remote_post_id}} = ActivityPub.Object.get_cached(ap_id: post_url)
          remote_post = Bonfire.Common.Needles.get!(remote_post_id, skip_boundary_check: true)
          Bonfire.Boundaries.can?(context[:remote][:user], :reply, remote_post)
        end)
      end

      assert remote_can_reply?.(), "control: they may reply there before the ban"

      # worked out here, since the URL of one of ours depends on which instance asks
      {:ok, %{ap_id: moderator_ap_id}} = ActivityPub.Actor.get_cached(pointer: moderator)

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        mirror_moderators =
          Bonfire.Classify.Categories.moderators(group_on_remote)
          |> Enum.map(&(ActivityPub.Actor.get_cached(pointer: &1) |> elem(1) |> e(:ap_id, nil)))

        assert moderator_ap_id in mirror_moderators,
               "control: the group's moderator (#{moderator_ap_id}) is a moderator of the follower's copy of it, so has standing there, got: #{inspect(mirror_moderators)}"
      end)

      assert {:ok, banned} =
               AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.block(banned, :silence,
                 current_user: moderator,
                 on_behalf_of: group[:category],
                 also_unfollow_and_notify: true,
                 reason: "spam"
               )

      refute remote_can_reply?.(), "the ban reaches their instance through the group"

      assert {:ok, _} =
               Bonfire.Boundaries.Blocks.unblock(banned, :silence,
                 current_user: moderator,
                 on_behalf_of: group[:category]
               )

      assert remote_can_reply?.(), "and so does lifting it"
    end

    # A report on a post in a group hosted elsewhere, with "Include my name for the group's moderators" ticked (`forward_to_group: true`), goes to the group as the reporter, and reaches the group's moderators where it is hosted; withdrawing it there sends its `Undo`, which withdraws it at the group's instance too
    test "reporting a post in a group hosted elsewhere reaches its moderators there, and withdrawing the report withdraws it there",
         context do
      %{post: post, post_url: post_url, moderator: moderator} =
        member_post_in_followed_group!(context, "a post someone elsewhere reports")

      refute Bonfire.Social.Flags.flagged_object?(post), "control: nobody reported it yet"

      remote_post =
        TestInstanceRepo.apply(fn ->
          {:ok, %{pointer_id: remote_post_id}} = ActivityPub.Object.get_cached(ap_id: post_url)
          remote_post = Bonfire.Common.Needles.get!(remote_post_id, skip_boundary_check: true)

          assert %{} = Bonfire.Social.Flags.remote_group_for_report(remote_post),
                 "control: there, the post is in a group hosted elsewhere, so the form offers sending it to the group"

          assert {:ok, _} =
                   Bonfire.Social.Flags.flag(context[:remote][:user], remote_post,
                     forward_to_group: true,
                     comment: "spam in the group"
                   )

          remote_post
        end)

      assert Bonfire.Social.Flags.flagged_object?(post), "the report reaches the group's instance"

      assert FeedLoader.feed_contains?(:notifications, post, current_user: moderator),
             "and the group's moderator"

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} = Bonfire.Social.Flags.unflag(context[:remote][:user], remote_post)
      end)

      refute Bonfire.Social.Flags.flagged_object?(post),
             "withdrawing it there withdraws it at the group's instance"
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
