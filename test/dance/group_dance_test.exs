if Bonfire.Common.Extend.extension_enabled?(:bonfire_classify) do
  defmodule Bonfire.Federate.ActivityPub.Dance.GroupTest do
    use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

    @moduletag :test_instance

    import Untangle
    import Bonfire.Common.Config, only: [repo: 0]
    import Bonfire.Federate.ActivityPub.SharedDataDanceCase
    import Bonfire.Classify.Simulate
    #  import AssertValue

    alias Bonfire.Common.TestInstanceRepo
    alias Bonfire.Federate.ActivityPub.AdapterUtils

    alias Bonfire.Posts
    alias Bonfire.Social.Graph.Follows

    # Builds a group ON THE PEER with the dimensions asked for. `fancy_fake_category_on_test_instance/2` alone would leave a group with default dimensions, since the dimensions are applied by `Boundaries.apply/3` rather than by the create attrs — so a declarations test written without this would assert against a group that never had the rules under test.
    defp remote_group!(context, dims) do
      creator = context[:remote][:user]

      TestInstanceRepo.apply(fn ->
        group = fake_group!(creator, %{type: :group})
        :ok = Bonfire.Classify.Boundaries.replace(group, creator, dims)

        [
          group: group,
          username: Bonfire.Me.Characters.display_username(group, true),
          canonical_url: Bonfire.Me.Characters.character_url(group)
        ]
      end)
    end

    @tag :test_instance
    test "a group's declared rules survive the wire", context do
      remote =
        remote_group!(context, %{
          membership: "on_request",
          visibility: "global",
          participation: "moderators",
          default_content_visibility: "public"
        })

      # the RAW actor, which is where declarations live
      assert {:ok, actor} =
               ActivityPub.Actor.get_cached_or_fetch(username: remote[:username])

      assert actor.data["postingRestrictedToMods"] == true,
             "a moderators-only community that does not say so gets people writing posts it will never accept"

      assert actor.data["openness"] == "moderated"
      assert actor.data["manuallyApprovesFollowers"] == true
      assert is_binary(actor.data["attributedTo"]), "its moderators collection, as a URI"

      # and the MIRROR, which is what those declarations become here
      assert {:ok, %Bonfire.Classify.Category{} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

      dims = Bonfire.Boundaries.Presets.group_dimension_slugs(mirror)

      assert dims[:participation] == "moderators"
      assert dims[:membership] == "on_request"
    end

    @tag :test_instance
    test "its moderators collection can be dereferenced from a peer", context do
      remote =
        remote_group!(context, %{
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

      mod = context[:remote][:user]

      # establish the moderator on the ORIGIN rather than assuming a creator is one: without this control, an empty served collection cannot be told apart from a group that has no moderators to serve
      TestInstanceRepo.apply(fn ->
        Bonfire.Classify.Categories.add_moderator(mod, remote[:group], id(mod))

        assert Bonfire.Classify.Categories.moderators(remote[:group]) != [],
               "control: the group has a moderator at its origin"
      end)

      assert {:ok, actor} =
               ActivityPub.Actor.get_cached_or_fetch(username: remote[:username])

      collection_url = actor.data["attributedTo"]
      assert is_binary(collection_url)

      assert {:ok, collection} =
               ActivityPub.Federator.Fetcher.fetch_collection(collection_url,
                 fetch_collection: true
               )

      # `fetch_collection/2` hands back the ITEMS themselves, already unwrapped — a plain list of ap_ids, not the collection map
      items = List.wrap(collection)

      refute items == [],
             "an empty list here means the origin served no members, which is what a PAGED collection looks like to Lemmy and PieFed: they read `orderedItems` off the top level and never follow `first`"

      assert Enum.any?(List.wrap(items), &String.contains?(to_string(&1), id(mod))),
             "a moderator missing from the served list cannot act for this group from their own instance.\nitems: #{inspect(items)}\nfetched from #{collection_url}: #{inspect(collection, limit: 20, printable_limit: 2000)}"
    end

    @tag :test_instance
    test "a nonfederated group is not fetchable from a peer", context do
      remote =
        remote_group!(context, %{
          membership: "local:members",
          visibility: "nonfederated:preview",
          participation: "local:contributors",
          default_content_visibility: "nonfederated"
        })

      refute match?(
               {:ok, %Bonfire.Classify.Category{}},
               AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])
             ),
             "nonfederated visibility denies the `activity_pub` circle, and being absent from feeds is not the same as being unfetchable — only a peer can show the difference"
    end

    defp join_verb, do: Bonfire.Boundaries.Verbs.get_id!(:join)

    # the local person as the peer knows them. Takes the URL rather than the user, because it has to be computed HERE, before `TestInstanceRepo.apply/1` switches to the peer's host config
    defp on_peer(url) do
      {:ok, there} = AdapterUtils.get_or_fetch_and_create_by_uri(url)
      there
    end

    # Pressing Join sends both a `Follow` and a `Join`, and leaving sends `Leave` and `Undo{Follow}`, so both instances have to agree on each half at every step
    @tag :test_instance
    test "joining an open remote group makes you a member and a follower on both sides, and leaving ends both",
         context do
      remote =
        remote_group!(context, %{
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

      local = context[:local][:user]

      assert {:ok, mirror} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])
      assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(local, mirror)

      assert Bonfire.Classify.Categories.member?(local, mirror)

      assert Follows.following?(local, mirror),
             "the group's Accept of the Follow did not come back"

      TestInstanceRepo.apply(fn ->
        joiner = on_peer(local)

        assert Bonfire.Classify.Categories.member?(joiner, remote[:group]),
               "the Join never made them a member at the group's origin"

        assert Follows.following?(joiner, remote[:group])
      end)

      assert {:ok, _} = Bonfire.Classify.Categories.leave_and_unfollow_group(local, mirror)
      refute Bonfire.Classify.Categories.member?(local, mirror)

      TestInstanceRepo.apply(fn ->
        joiner = on_peer(local)

        refute Bonfire.Classify.Categories.member?(joiner, remote[:group]),
               "the Leave never reached the group's origin"

        refute Follows.following?(joiner, remote[:group])
      end)
    end

    # the moderator's decision at the origin is the only thing that can settle a pending join here, so it has to be sent back
    @tag :test_instance
    test "joining a remote group that reviews joins waits, and its moderator accepting makes you a member here too",
         context do
      remote =
        remote_group!(context, %{
          membership: "on_request",
          visibility: "global",
          participation: "group_members",
          default_content_visibility: "public"
        })

      local = context[:local][:user]
      creator = context[:remote][:user]

      assert {:ok, mirror} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])
      assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(local, mirror)

      refute Bonfire.Classify.Categories.member?(local, mirror), "the group has not decided yet"
      assert Bonfire.Social.Requests.requested?(local, join_verb(), mirror)

      TestInstanceRepo.apply(fn ->
        joiner = on_peer(local)

        assert [request] =
                 Bonfire.Social.Requests.all_by_object(remote[:group], join_verb(),
                   skip_boundary_check: true
                 ),
               "the Join did not arrive as a join request at the group's origin"

        assert {:ok, _} = Bonfire.Classify.Categories.accept_join_request(creator, request)
        assert Bonfire.Classify.Categories.member?(joiner, remote[:group])
      end)

      assert Bonfire.Classify.Categories.member?(local, mirror),
             "accepted at the origin, but no Accept of the Join came back, so the joiner's own instance still shows them waiting"

      refute Bonfire.Social.Requests.requested?(local, join_verb(), mirror)
    end

    @tag :test_instance
    test "can lookup group actors from AP API with username, AP ID and with friendly URL",
         context do
      # lookup 3 separate users to be sure
      creator = context[:remote][:user]

      remote = fancy_fake_category_on_test_instance(creator)

      {:ok, %Bonfire.Classify.Category{} = object} =
        AdapterUtils.get_by_url_ap_id_or_username(remote[:username])

      assert object.profile.name == remote[:category].profile.name

      {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(username: remote[:username])
      assert actor.data["type"] == "Group"

      remote = fancy_fake_category_on_test_instance(creator)

      assert {:ok, %Bonfire.Classify.Category{} = object} =
               AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

      assert object.profile.name == remote[:category].profile.name

      remote = fancy_fake_category_on_test_instance(creator)

      assert {:ok, %Bonfire.Classify.Category{} = object} =
               AdapterUtils.get_by_url_ap_id_or_username(remote[:friendly_url])

      assert object.profile.name == remote[:category].profile.name
    end
  end
end
