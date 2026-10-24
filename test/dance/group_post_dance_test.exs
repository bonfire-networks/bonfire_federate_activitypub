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

    # The `announcement_channel` preset, read from the config: people follow it and only its moderators post. A follower on another instance gets the moderator's post, and what they reply to it comes back to the channel's instance
    test "an announcement channel's post reaches a follower on the other instance, and their reply comes back",
         context do
      moderator = context[:local][:user]
      preset = Bonfire.Boundaries.Presets.group_preset_meta("announcement_channel")

      group =
        fancy_fake_category!(
          moderator,
          [type: :group] ++
            Map.to_list(Map.take(preset, [:membership, :visibility, :participation]))
        )

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        assert {:ok, _} = Follows.follow(context[:remote][:user], group_on_remote)
      end)

      {:ok, post} =
        Posts.publish(
          current_user: moderator,
          post_attrs: %{post_content: %{html_body: "an announcement from the channel"}},
          boundary: "public",
          publish_in: id(group[:category])
        )

      post_url =
        post
        |> repo().maybe_preload([:peered, created: [:peered]])
        |> Bonfire.Common.URIs.canonical_url()

      reply_url =
        TestInstanceRepo.apply(fn ->
          assert {:ok, group_on_remote} =
                   AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

          assert FeedLoader.feed_contains?(
                   :user_activities,
                   "an announcement from the channel",
                   by: group_on_remote,
                   current_user: context[:remote][:user]
                 ),
                 "the follower got the moderator's post"

          assert {:ok, reply} =
                   Posts.publish(
                     current_user: context[:remote][:user],
                     post_attrs: %{
                       post_content: %{html_body: "a reply from a follower"},
                       reply_to_id: id(their_copy(post_url))
                     },
                     boundary: "public"
                   )

          reply
          |> repo().maybe_preload([:peered, created: [:peered]])
          |> Bonfire.Common.URIs.canonical_url()
        end)

      assert {:ok, %{pointer_id: reply_id}} = ActivityPub.Object.get_cached(ap_id: reply_url),
             "the reply never reached the channel's instance"

      assert {:ok, reply} = Posts.read(reply_id, skip_boundary_check: true)
      assert e(reply, :post_content, :html_body, nil) =~ "a reply from a follower"
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

    # A like is addressed to the post's author and to the group, not to the liker's own followers, so a server that follows the group and nobody on this one only hears of it from the group's `Announce`. Taking the like back is announced the same way (`Undo{Like}`).
    test "a like on a member's post in a group reaches a follower's instance through the group, and taking it back does too",
         context do
      %{moderator: voter, post: post, post_url: post_url} =
        member_post_in_followed_group!(context, "a member's post that gets a like")

      voter_url = Bonfire.Common.URIs.canonical_url(voter)

      voter_liked_there? = fn ->
        TestInstanceRepo.apply(fn ->
          {:ok, voter_there} = AdapterUtils.get_or_fetch_and_create_by_uri(voter_url)
          Bonfire.Social.Likes.liked?(voter_there, their_copy(post_url))
        end)
      end

      refute voter_liked_there?.(), "control: no like there yet"

      assert {:ok, _} = Bonfire.Social.Likes.like(voter, post)

      assert voter_liked_there?.(), "the like reaches the follower's instance through the group"

      assert {:ok, _} = Bonfire.Social.Likes.unlike(voter, post)

      refute voter_liked_there?.(), "and so does taking it back"
    end

    # A moderator of a group here who is on another instance acts through their own instance's copy of the group: their `Lock` goes to the group, which applies it if they are one of its moderators. Someone there who isn't is refused before anything is sent, and a `Lock` made up in their name and delivered here is refused here (mocked counterparts: `threadiverse_moderation_test.exs`, describe "a moderator here of a community elsewhere", and the `Lock` refusal pair)
    defp moderator_on_other_instance!(context, html_body) do
      %{moderator: moderator, group: group} =
        setup = member_post_in_followed_group!(context, html_body)

      assert {:ok, remote_moderator} =
               AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

      assert {:ok, _} =
               Bonfire.Classify.Categories.add_moderator(
                 moderator,
                 group[:category],
                 id(remote_moderator)
               ),
             "control: the follower on the other instance is made a moderator here"

      setup
    end

    defp their_copy(post_url) do
      {:ok, %{pointer_id: remote_post_id}} = ActivityPub.Object.get_cached(ap_id: post_url)
      Bonfire.Common.Needles.get!(remote_post_id, skip_boundary_check: true)
    end

    test "a moderator on another instance locking a post in a group here locks it here",
         context do
      %{group: group, post: post, post_url: post_url} =
        moderator_on_other_instance!(context, "a thread a moderator elsewhere closes")

      refute Bonfire.Boundaries.Blocks.is_blocked?(id(post), :lock), "control: open here"

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        assert Bonfire.Boundaries.can?(context[:remote][:user], :mediate, group_on_remote),
               "control: their instance knows them as a moderator of its copy of the group"

        assert {:ok, _} =
                 Bonfire.Boundaries.Blocks.lock(their_copy(post_url),
                   current_user: context[:remote][:user]
                 )
      end)

      assert Bonfire.Boundaries.Blocks.is_blocked?(id(post), :lock),
             "their Lock reaches the group, which applies it"
    end

    # what the moderator's own instance does with it: waiting for the group, applied when the group echoes it back
    test "a moderator on another instance locking a post in a group here closes their own copy once the group applies it",
         context do
      %{post: post, post_url: post_url} =
        moderator_on_other_instance!(context, "a thread closed from elsewhere, and there")

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Bonfire.Boundaries.Blocks.lock(their_copy(post_url),
                   current_user: context[:remote][:user]
                 )
      end)

      assert Bonfire.Boundaries.Blocks.is_blocked?(id(post), :lock), "control: applied here"

      TestInstanceRepo.apply(fn ->
        assert Bonfire.Boundaries.Blocks.is_blocked?(id(their_copy(post_url)), :lock),
               "the group's echo closes the moderator's own copy"
      end)
    end

    # A group refusing a moderator's action tells them, so their instance takes back what it applied straight away (`apply_now`). The moderator is demoted here without their instance being told (out of the moderators circle directly, where `remove_moderator/4` would send a `Remove`), so it still takes them for one and sends the lock
    test "a lock the group refuses, applied at once by a moderator on another instance, is taken back there",
         context do
      %{group: group, post: post, post_url: post_url} =
        moderator_on_other_instance!(context, "a thread a demoted moderator elsewhere closes")

      assert {:ok, remote_moderator} =
               AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

      {:ok, circle} = Bonfire.Classify.Categories.moderators_circle(group[:category])
      Bonfire.Boundaries.Circles.remove_from_circles(remote_moderator, [circle])

      refute Bonfire.Boundaries.can?(remote_moderator, :mediate, group[:category]),
             "control: no longer a moderator here"

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Bonfire.Boundaries.Blocks.lock(their_copy(post_url),
                   current_user: context[:remote][:user],
                   apply_now: true
                 ),
               "their instance still takes them for a moderator"
      end)

      refute Bonfire.Boundaries.Blocks.is_blocked?(id(post), :lock), "refused here"

      TestInstanceRepo.apply(fn ->
        refute Bonfire.Boundaries.Blocks.is_blocked?(id(their_copy(post_url)), :lock),
               "the group's Reject reopens the moderator's own copy"
      end)
    end

    test "someone on another instance who doesn't moderate a group here can't lock its posts from there",
         context do
      %{post: post, post_url: post_url} =
        member_post_in_followed_group!(context, "a thread a stranger elsewhere tries to close")

      TestInstanceRepo.apply(fn ->
        assert {:error, _} =
                 Bonfire.Boundaries.Blocks.lock(their_copy(post_url), current_user: fake_user!()),
               "refused there, before anything is sent"
      end)

      refute Bonfire.Boundaries.Blocks.is_blocked?(id(post), :lock)
    end

    test "a Lock made up in the name of someone on another instance who doesn't moderate the group is refused here",
         context do
      %{group: group, post: post, post_url: post_url} =
        moderator_on_other_instance!(context, "a thread someone forges a Lock for")

      # their URLs as their own instance gives them
      {stranger_ap_id, moderator_ap_id} =
        TestInstanceRepo.apply(fn ->
          {:ok, %{ap_id: stranger}} = ActivityPub.Actor.get_cached(pointer: fake_user!())

          {:ok, %{ap_id: moderator}} =
            ActivityPub.Actor.get_cached(pointer: context[:remote][:user])

          {stranger, moderator}
        end)

      {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group[:category])

      lock_from = fn actor ->
        ActivityPub.Federator.Transformer.handle_incoming(%{
          "id" => actor <> "/lock/#{System.unique_integer([:positive])}",
          "type" => "Lock",
          "actor" => actor,
          "object" => post_url,
          "to" => [group_ap_id],
          "audience" => group_ap_id
        })
      end

      lock_from.(stranger_ap_id)

      refute Bonfire.Boundaries.Blocks.is_blocked?(id(post), :lock),
             "someone with no standing in the group can't close its threads"

      lock_from.(moderator_ap_id)

      assert Bonfire.Boundaries.Blocks.is_blocked?(id(post), :lock),
             "control: the same Lock from one of its moderators there closes it, so the refusal above is about who sent it"
    end

    # The rest of a moderator's actions, each across instances (the group plan's inventory against `moderation-log.md`'s verbs)

    # The `Undo` embeds the `Lock` it takes back, so the follower's instance reopens the thread that `Lock` names (`Blocks.ap_receive_locked_object/1`), not the embedded activity
    test "a moderator unlocking a member's post in a group reopens it on a follower's instance",
         context do
      %{moderator: moderator, post: post, post_url: post_url} =
        member_post_in_followed_group!(context, "a thread closed then reopened")

      remote_post_open? = fn ->
        TestInstanceRepo.apply(fn ->
          Bonfire.Boundaries.can?(context[:remote][:user], :reply, their_copy(post_url))
        end)
      end

      assert {:ok, _} = Bonfire.Boundaries.Blocks.lock(post, current_user: moderator)
      refute remote_post_open?.(), "control: the lock reached the follower's instance"

      assert {:ok, _} = Bonfire.Boundaries.Blocks.unlock(post, current_user: moderator)
      assert remote_post_open?.(), "the unlock reaches it too"
    end

    test "demoting a moderator at the group's origin removes them from a follower's mirror's moderators",
         context do
      %{moderator: moderator, group: group} =
        moderator_on_other_instance!(context, "a post in a group whose moderator is demoted")

      remote_is_moderator_there? = fn ->
        TestInstanceRepo.apply(fn ->
          assert {:ok, group_on_remote} =
                   AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

          Bonfire.Boundaries.can?(context[:remote][:user], :mediate, group_on_remote)
        end)
      end

      assert remote_is_moderator_there?.(), "control: promoted, and their mirror knows"

      assert {:ok, remote_moderator} =
               AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

      assert {:ok, _} =
               Bonfire.Classify.Categories.remove_moderator(
                 moderator,
                 group[:category],
                 id(remote_moderator)
               )

      refute remote_is_moderator_there?.(), "the demotion reaches the mirror"
    end

    # `silence` is the ban tested above. A ghost alone sends nothing to the other instance. A block also sends the group's own `Block` to the person's instance, which acts on it as the group blocking them: they can neither read nor reply there. On the group's own instance both keep the person from reading
    for {type, can_read_on_peer?, can_reply_on_peer?} <- [
          {:ghost, true, true},
          {:block, false, false}
        ] do
      test "a #{type} ban from a group #{if can_reply_on_peer?, do: "leaves them as they were on the other instance", else: "is a block on the other instance"}, and keeps them from reading here",
           context do
        %{moderator: moderator, group: group, post: post, post_url: post_url} =
          member_post_in_followed_group!(context, "a post the #{unquote(type)}ed person loses")

        remote_can? = fn verb ->
          TestInstanceRepo.apply(fn ->
            Bonfire.Boundaries.can?(context[:remote][:user], verb, their_copy(post_url))
          end)
        end

        assert remote_can?.(:read), "control: they may read it there before the ban"
        assert remote_can?.(:reply), "control: and reply"

        assert {:ok, banned} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

        assert Bonfire.Boundaries.can?(banned, :read, post),
               "control: they may read it here before the ban"

        assert {:ok, _} =
                 Bonfire.Boundaries.Blocks.block(banned, unquote(type),
                   current_user: moderator,
                   on_behalf_of: group[:category],
                   also_unfollow_and_notify: true,
                   reason: "spam"
                 )

        refute Bonfire.Boundaries.can?(banned, :read, post),
               "the ban holds on the group's own instance"

        assert remote_can?.(:read) == unquote(can_read_on_peer?)
        assert remote_can?.(:reply) == unquote(can_reply_on_peer?)
      end
    end

    test "a moderator on another instance removing a post from a group here takes it out of the group here",
         context do
      %{group: group, post: post, post_url: post_url} =
        moderator_on_other_instance!(context, "a post a moderator elsewhere removes")

      assert FeedLoader.feed_contains?(:user_activities, post,
               by: group[:category],
               current_user: context[:local][:user]
             ),
             "control: in the group here"

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        assert FeedLoader.feed_contains?(:user_activities, their_copy(post_url),
                 by: group_on_remote,
                 current_user: context[:remote][:user]
               ),
               "control: in their copy of the group too"

        assert {:ok, _} =
                 Bonfire.Classify.Categories.remove_post_from_group(
                   context[:remote][:user],
                   group_on_remote,
                   their_copy(post_url)
                 )
      end)

      refute FeedLoader.feed_contains?(:user_activities, post,
               by: group[:category],
               current_user: context[:local][:user]
             ),
             "their removal reaches the group, which takes it out"

      assert post_held?(post_url), "the post itself stays"

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        refute FeedLoader.feed_contains?(:user_activities, their_copy(post_url),
                 by: group_on_remote,
                 current_user: context[:remote][:user]
               ),
               "and the group's echo takes it out of the moderator's own copy of the group"
      end)
    end

    test "a moderator on another instance banning someone in a group here bans them here",
         context do
      %{group: group, post: post, post_url: post_url} =
        moderator_on_other_instance!(
          context,
          "a post someone a moderator elsewhere bans replied to"
        )

      # another member, not the post's author: `can?/3` lets anyone act on what they created without a boundary check, so the author would still pass
      member = fake_user!()

      assert {:ok, _} =
               Bonfire.Classify.Categories.join_and_follow_group(member, group[:category])

      assert Bonfire.Boundaries.can?(member, :reply, post), "control: the member may reply"

      {:ok, %{ap_id: member_ap_id}} = ActivityPub.Actor.get_cached(pointer: member)

      TestInstanceRepo.apply(fn ->
        assert {:ok, group_on_remote} =
                 AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

        assert {:ok, member_there} = AdapterUtils.get_or_fetch_and_create_by_uri(member_ap_id)

        assert Bonfire.Boundaries.can?(member_there, :reply, their_copy(post_url)),
               "control: they may reply in the moderator's copy too, before the ban"

        assert {:ok, _} =
                 Bonfire.Boundaries.Blocks.block(member_there, :silence,
                   current_user: context[:remote][:user],
                   on_behalf_of: group_on_remote,
                   also_unfollow_and_notify: true,
                   reason: "spam"
                 )
      end)

      refute Bonfire.Boundaries.can?(member, :reply, post),
             "their ban reaches the group, which applies it"

      TestInstanceRepo.apply(fn ->
        assert {:ok, member_there} = AdapterUtils.get_or_fetch_and_create_by_uri(member_ap_id)

        refute Bonfire.Boundaries.can?(member_there, :reply, their_copy(post_url)),
               "and the group's echo bans them in the moderator's own copy of the group"
      end)
    end

    # Deleting, in each place it can start (mocked counterparts: `group_remote_posting_test.exs`, `remote_moderation_apply_now_ui_test.exs`, `delete_permissions_test.exs`). Lemmy accepts a `Delete` of a post from anyone on the post's own instance, so the author's and their admin's both count; a moderator elsewhere erases only their own copy

    test "someone on another instance deleting their post in a group here deletes it here",
         context do
      %{remote_post_id: remote_post_id, post_url: post_url} =
        remote_member_post_in_group!(context, "a post from elsewhere, about to be deleted")

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Bonfire.Social.Objects.delete(remote_post_id,
                   current_user: context[:remote][:user]
                 )
      end)

      refute post_held?(post_url), "the author's deletion reaches the group's instance"
    end

    test "an admin on another instance deleting a post of theirs in a group here deletes it here",
         context do
      %{remote_post_id: remote_post_id, post_url: post_url} =
        remote_member_post_in_group!(context, "a post its admin will delete")

      TestInstanceRepo.apply(fn ->
        {:ok, admin} = Bonfire.Me.Users.make_admin(fake_user!())
        assert {:ok, _} = Bonfire.Social.Objects.delete(remote_post_id, current_user: admin)
      end)

      refute post_held?(post_url), "a deletion from the post's own instance reaches the group's"
    end

    # The group's followers on a THIRD instance are who needs these two, and a dance has two instances, so this can only look at what the group's instance does with the activity it received over the wire: it announces it (mocked counterparts, which can read the outgoing side too: `group_incoming_post_test.exs`)
    test "an edit by someone on another instance of their post in a group here is announced by the group",
         context do
      %{group: group, post_url: post_url, remote_post_id: remote_post_id} =
        remote_member_post_in_group!(context, "a post from elsewhere, about to be edited")

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Bonfire.Social.PostContents.edit(context[:remote][:user], remote_post_id, %{
                   html_body: "the same post from elsewhere after its edit"
                 })

        assert updates_of(post_url) == 1,
               "the author's instance publishes the edit once: the group's relay of it coming back is not applied, and so not published, again"
      end)

      assert %{} = update = ActivityPub.Object.get_activity_for_object_ap_id(post_url, "Update"),
             "control: the author's edit reached the group's instance"

      assert updates_of(post_url) == 1, "and reached it once"

      {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group[:category])

      assert %{data: %{"type" => "Announce"}} =
               ActivityPub.Object.get_existing_announce(group_ap_id, update),
             "the group announces the edit, so its followers on other instances get it"
    end

    # FEP-8b32 with FEP-1b12: the author's instance signs the edit, delivers it over its HTTP signature, and the group checks the author's proof before relaying it as it arrived, so it still verifies for whoever gets the group's Announce. What a follower of the group then sees needs a third instance, which a dance does not have (the author's instance gets its own edit back, and has nothing to verify about its own activity); the relayed bytes are checked in the library's `relayed_received_document_test.exs`.
    test "a member's signed edit is checked by its proof when the group relays it", context do
      %{post_url: post_url, remote_post_id: remote_post_id} =
        remote_member_post_in_group!(
          context,
          "a post from elsewhere, about to be edited and signed"
        )

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Bonfire.Social.PostContents.edit(context[:remote][:user], remote_post_id, %{
                   html_body: "the same post after its signed edit"
                 })
      end)

      assert %{} = update = ActivityPub.Object.get_activity_for_object_ap_id(post_url, "Update")

      assert update.authenticated == :integrity_proof,
             "delivered over its HTTP signature, the edit is marked as vouched for by its proof only once the group checked that proof to relay it unchanged"
    end

    test "a deletion by someone on another instance of their post in a group here is announced by the group",
         context do
      %{group: group, post_url: post_url, remote_post_id: remote_post_id} =
        remote_member_post_in_group!(context, "a post from elsewhere, about to be deleted again")

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Bonfire.Social.Objects.delete(remote_post_id,
                   current_user: context[:remote][:user]
                 )
      end)

      assert %{} = delete = ActivityPub.Object.get_activity_for_object_ap_id(post_url, "Delete"),
             "control: the author's deletion reached the group's instance"

      {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: group[:category])

      assert %{data: %{"type" => "Announce"}} =
               ActivityPub.Object.get_existing_announce(group_ap_id, delete),
             "the group announces the deletion, so followers that ignore an `Undo{Announce}` drop the post"
    end

    test "a moderator on another instance deleting a member's post in a group here erases only their own copy",
         context do
      %{moderator: moderator, group: group, post_url: post_url} =
        member_post_in_followed_group!(context, "a post a moderator elsewhere deletes")

      assert {:ok, remote_moderator} =
               AdapterUtils.get_or_fetch_and_create_by_uri(context[:remote][:canonical_url])

      assert {:ok, _} =
               Bonfire.Classify.Categories.add_moderator(
                 moderator,
                 group[:category],
                 id(remote_moderator)
               ),
             "control: the follower on the other instance is made a moderator here"

      TestInstanceRepo.apply(fn ->
        {:ok, %{pointer_id: remote_post_id}} = ActivityPub.Object.get_cached(ap_id: post_url)

        assert {:ok, _} =
                 Bonfire.Social.Objects.delete(remote_post_id,
                   current_user: context[:remote][:user]
                 )

        refute post_held?(post_url), "erased on their own instance"
      end)

      assert post_held?(post_url), "still here, where the post lives"
    end

    test "an instance moderator deleting a member's post in a group deletes it on a follower's instance",
         context do
      %{post: post, post_url: post_url} =
        member_post_in_followed_group!(context, "a post an instance moderator deletes")

      instance_moderator = Bonfire.Me.Fake.instance_moderator!(fake_user!())
      assert {:ok, _} = Bonfire.Social.Objects.delete(post, current_user: instance_moderator)

      TestInstanceRepo.apply(fn ->
        refute post_held?(post_url), "the deletion reaches the follower's instance"
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

      {remote_post, reporter_ap_id} =
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

          {:ok, %{ap_id: ap_id}} = ActivityPub.Actor.get_cached(pointer: context[:remote][:user])
          {remote_post, ap_id}
        end)

      assert Bonfire.Social.Flags.flagged_object?(post), "the report reaches the group's instance"

      # what the anonymous report below is compared against
      assert {:ok, reporter_here} = AdapterUtils.get_or_fetch_and_create_by_uri(reporter_ap_id)

      assert Bonfire.Social.Flags.flagged?(reporter_here, post),
             "a named report is the reporter's, here too"

      assert FeedLoader.feed_contains?(:notifications, post, current_user: moderator),
             "and the group's moderator"

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} = Bonfire.Social.Flags.unflag(context[:remote][:user], remote_post)
      end)

      refute Bonfire.Social.Flags.flagged_object?(post),
             "withdrawing it there withdraws it at the group's instance"
    end

    # The group's moderators may be on other instances, and a report has to reach them there too. Lemmy relays a report its community receives to every moderator's inbox, as the community's `Announce{Flag}` (`crates/apub/activities/src/community/report.rs:180-187`, `report_inboxes`)
    # the reporter chooses, with the flag form's checkboxes: anonymously (`forward`) or named (`forward_to_group`); unticked, it stays here
    for {how, opts} <- [anonymously: [forward: true], named: [forward_to_group: true]] do
      test "a report on a post in a group here reaches the group's moderator on another instance, #{how}",
           context do
        %{post: post, post_url: post_url} =
          moderator_on_other_instance!(context, "a post reported to a moderator elsewhere")

        assert {:ok, _} =
                 Bonfire.Social.Flags.flag(
                   fake_user!(),
                   post,
                   [comment: "spam in the group"] ++ unquote(opts)
                 )

        assert Bonfire.Social.Flags.flagged_object?(post), "control: reported here"

        TestInstanceRepo.apply(fn ->
          remote_post = their_copy(post_url)

          assert Bonfire.Social.Flags.flagged_object?(remote_post),
                 "the report reaches the moderator's instance"

          assert FeedLoader.feed_contains?(:notifications, remote_post,
                   current_user: context[:remote][:user]
                 ),
                 "and the moderator, in their notifications"
        end)
      end
    end

    test "a report on a post in a group here, with neither box ticked, stays here", context do
      %{post: post, post_url: post_url} =
        moderator_on_other_instance!(context, "a post reported only here")

      assert {:ok, _} =
               Bonfire.Social.Flags.flag(fake_user!(), post, comment: "spam in the group")

      assert Bonfire.Social.Flags.flagged_object?(post), "control: reported here"

      TestInstanceRepo.apply(fn ->
        refute Bonfire.Social.Flags.flagged_object?(their_copy(post_url)),
               "nothing sent without the reporter's say"
      end)
    end

    # With only "Forward anonymously to remote moderators" ticked (`forward: true`), the report goes from a service actor, and names the group as well as the post's instance (`Flags.anonymous_to_group/2`), so the group's moderators get it without learning who sent it
    test "reporting a post in a group hosted elsewhere anonymously reaches its moderators there, without the reporter's name",
         context do
      %{post: post, post_url: post_url, moderator: moderator} =
        member_post_in_followed_group!(context, "a post someone elsewhere reports anonymously")

      refute Bonfire.Social.Flags.flagged_object?(post), "control: nobody reported it yet"

      reporter_ap_id =
        TestInstanceRepo.apply(fn ->
          {:ok, %{pointer_id: remote_post_id}} = ActivityPub.Object.get_cached(ap_id: post_url)
          remote_post = Bonfire.Common.Needles.get!(remote_post_id, skip_boundary_check: true)

          assert {:ok, _} =
                   Bonfire.Social.Flags.flag(context[:remote][:user], remote_post,
                     forward: true,
                     comment: "anonymous spam report"
                   )

          {:ok, %{ap_id: ap_id}} = ActivityPub.Actor.get_cached(pointer: context[:remote][:user])
          ap_id
        end)

      assert Bonfire.Social.Flags.flagged_object?(post), "the report reaches the group's instance"

      assert FeedLoader.feed_contains?(:notifications, post, current_user: moderator),
             "and the group's moderator"

      assert {:ok, reporter_here} = AdapterUtils.get_or_fetch_and_create_by_uri(reporter_ap_id)

      refute Bonfire.Social.Flags.flagged?(reporter_here, post),
             "sent without the reporter's name: here, the report isn't theirs"
    end

    # whether this instance still holds a post, by its URL
    # how many `Update`s of this object the current instance holds
    defp updates_of(object_ap_id) do
      import Ecto.Query

      from(o in ActivityPub.Object,
        where:
          fragment("?->>'type'", o.data) == "Update" and
            fragment("coalesce(?->'object'->>'id', ?->>'object')", o.data, o.data) ==
              ^object_ap_id
      )
      |> repo().aggregate(:count)
    end

    defp post_held?(post_url) do
      with {:ok, %{pointer_id: id}} when is_binary(id) <-
             ActivityPub.Object.get_cached(ap_id: post_url),
           {:ok, _} <- Bonfire.Common.Needles.get(id, skip_boundary_check: true) do
        true
      else
        _ -> false
      end
    end

    # someone on the other instance joins a group hosted here and posts in it from there, as their group-page composer does (`group_live.sface`'s smart input opts)
    defp remote_member_post_in_group!(context, html_body) do
      group =
        fancy_fake_category!(context[:local][:user],
          type: :group,
          membership: "open",
          visibility: "global",
          participation: "anyone"
        )

      {remote_post_id, post_url} =
        TestInstanceRepo.apply(fn ->
          assert {:ok, group_on_remote} =
                   AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

          author = context[:remote][:user]

          assert {:ok, _} =
                   Bonfire.Classify.Categories.join_and_follow_group(author, group_on_remote)

          {:ok, post} =
            Posts.publish(
              current_user: author,
              post_attrs: %{post_content: %{html_body: html_body}},
              context_id: id(group_on_remote),
              to_circles: Bonfire.Classify.Boundaries.post_circles_for_group(group_on_remote),
              to_boundaries:
                List.wrap(
                  Bonfire.Classify.Boundaries.read_default_content_visibility(group_on_remote)
                )
            )

          {id(post),
           post
           |> repo().maybe_preload([:peered, created: [:peered]])
           |> Bonfire.Common.URIs.canonical_url()}
        end)

      assert post_held?(post_url), "control: the post reached the group's instance"

      %{group: group, remote_post_id: remote_post_id, post_url: post_url}
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

    # A titled post that starts a thread in a group goes out as a `Page` (so Mbin files it as a thread), and what the follower's Bonfire files it as depends on its primary image: none is a Post, a flagged cover makes it Media. A titled post outside a group stays a `Note` and arrives as a Post.
    describe "a titled post across instances" do
      defp titled_post_in(user, group, medias, opts) do
        {:ok, post} =
          Posts.publish(
            [
              current_user: user,
              post_attrs: %{
                post_content: %{name: "A thread title", html_body: "the body of the thread"},
                uploaded_media: medias
              },
              boundary: "public"
            ] ++ if(opts[:in_group], do: [publish_in: id(group[:category])], else: [])
          )

        post
      end

      defp upload_image(user, file, metadata \\ %{}) do
        assert {:ok, media} =
                 Bonfire.Files.upload(Bonfire.Files.ImageUploader, user, file, %{
                   metadata: metadata
                 })

        media
      end

      defp sent_type(post) do
        assert {:ok, %{data: data}} = ActivityPub.Object.get_cached(pointer: post)
        data["type"]
      end

      # what the follower's instance filed the post as, and how many media it kept attached
      defp filed_on_remote(context, group, post) do
        post_url =
          post
          |> repo().maybe_preload([:peered, created: [:peered]])
          |> Bonfire.Common.URIs.canonical_url()

        TestInstanceRepo.apply(fn ->
          assert {:ok, %{pointer_id: remote_id}} = ActivityPub.Object.get_cached(ap_id: post_url),
                 "the post reached the follower's instance"

          received =
            Bonfire.Common.Needles.get!(remote_id, skip_boundary_check: true)
            |> repo().maybe_preload([:post_content, :media], prune: true)

          %{
            kind: received.__struct__,
            title: e(received, :post_content, :name, nil),
            media: length(List.wrap(e(received, :media, []))),
            in_group?:
              FeedLoader.feed_contains?(:user_activities, remote_id,
                by: elem(AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url]), 1),
                current_user: context[:remote][:user]
              )
          }
        end)
      end

      defp group_with_remote_follower(context) do
        user = context[:local][:user]

        group =
          fancy_fake_category!(user,
            type: :group,
            membership: "open",
            visibility: "global",
            participation: "anyone"
          )

        TestInstanceRepo.apply(fn ->
          assert {:ok, group_on_remote} =
                   AdapterUtils.get_or_fetch_and_create_by_uri(group[:canonical_url])

          assert {:ok, _} = Follows.follow(context[:remote][:user], group_on_remote)
        end)

        group
      end

      test "with no image is sent as a Page and filed as a Post, with its title", context do
        user = context[:local][:user]
        group = group_with_remote_follower(context)

        post = titled_post_in(user, group, [], in_group: true)

        assert sent_type(post) == "Page"

        assert %{
                 kind: Bonfire.Data.Social.Post,
                 title: "A thread title",
                 in_group?: group_activity
               } =
                 filed_on_remote(context, group, post)

        assert group_activity
      end

      test "with an image that is not the cover is sent as a Page and filed as a Post that keeps the image",
           context do
        user = context[:local][:user]
        group = group_with_remote_follower(context)

        post =
          titled_post_in(
            user,
            group,
            [upload_image(user, Bonfire.Files.Simulation.image_file())],
            in_group: true
          )

        assert sent_type(post) == "Page"

        assert %{kind: Bonfire.Data.Social.Post, media: 1} =
                 filed_on_remote(context, group, post)
      end

      test "with two images that are not the cover is a Post that keeps both", context do
        user = context[:local][:user]
        group = group_with_remote_follower(context)

        post =
          titled_post_in(
            user,
            group,
            [
              upload_image(user, Bonfire.Files.Simulation.image_file()),
              upload_image(user, Bonfire.Files.Simulation.image_with_exif_file())
            ],
            in_group: true
          )

        assert sent_type(post) == "Page"

        assert %{kind: Bonfire.Data.Social.Post, media: 2} =
                 filed_on_remote(context, group, post)
      end

      test "with an image flagged as the cover is sent as a Page and filed as Media", context do
        user = context[:local][:user]
        group = group_with_remote_follower(context)

        post =
          titled_post_in(
            user,
            group,
            [
              upload_image(user, Bonfire.Files.Simulation.image_file(), %{"primary_image" => true})
            ],
            in_group: true
          )

        assert sent_type(post) == "Page"
        assert %{kind: Bonfire.Files.Media} = filed_on_remote(context, group, post)
      end

      test "outside a group is sent as a Note and filed as a Post", context do
        user = context[:local][:user]
        group = group_with_remote_follower(context)

        # the follower follows the AUTHOR here, since a post outside a group reaches them through that follow and not the group's
        TestInstanceRepo.apply(fn ->
          assert {:ok, author_on_remote} =
                   AdapterUtils.get_or_fetch_and_create_by_uri(context[:local][:canonical_url])

          assert {:ok, _} = Follows.follow(context[:remote][:user], author_on_remote)
        end)

        post = titled_post_in(user, group, [], in_group: false)

        assert sent_type(post) == "Note"

        assert %{kind: Bonfire.Data.Social.Post, title: "A thread title"} =
                 filed_on_remote(context, group, post)
      end
    end
  end
end
