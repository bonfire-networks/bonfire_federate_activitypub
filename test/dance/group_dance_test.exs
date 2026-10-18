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

    # Unlisted is about LISTING, not access: the peer still mirrors the group, just without granting anyone `see`, so it stays out of the directory there too. Lemmy 1.0 reads `discoverable: false` the same way (its Unlisted visibility)
    @tag :test_instance
    test "an unlisted group stays unlisted on a peer", context do
      remote =
        remote_group!(context, %{
          membership: "open",
          visibility: "unlisted",
          participation: "anyone",
          default_content_visibility: "public"
        })

      assert {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(username: remote[:username])

      assert actor.data["discoverable"] == false,
             "an unlisted group that declares itself discoverable gets listed by every peer"

      assert {:ok, %Bonfire.Classify.Category{} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

      assert Bonfire.Boundaries.Presets.group_dimension_slugs(mirror)[:visibility] == "unlisted"
    end

    # the control for the test above: without it, a peer that declared every group undiscoverable would pass
    @tag :test_instance
    test "a listed group stays listed on a peer", context do
      remote =
        remote_group!(context, %{
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

      assert {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(username: remote[:username])
      assert actor.data["discoverable"] == true

      assert {:ok, %Bonfire.Classify.Category{} = mirror} =
               AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

      assert Bonfire.Boundaries.Presets.group_dimension_slugs(mirror)[:visibility] == "global"
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
      local_url = Bonfire.Me.Characters.character_url(local)

      assert {:ok, mirror} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])
      assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(local, mirror)

      assert Bonfire.Classify.Categories.member?(local, mirror)

      assert Follows.following?(local, mirror),
             "the group's Accept of the Follow did not come back"

      TestInstanceRepo.apply(fn ->
        joiner = on_peer(local_url)

        assert Bonfire.Classify.Categories.member?(joiner, remote[:group]),
               "the Join never made them a member at the group's origin"

        assert Follows.following?(joiner, remote[:group])
      end)

      assert {:ok, _} = Bonfire.Classify.Categories.leave_and_unfollow_group(local, mirror)
      refute Bonfire.Classify.Categories.member?(local, mirror)

      TestInstanceRepo.apply(fn ->
        joiner = on_peer(local_url)

        refute Bonfire.Classify.Categories.member?(joiner, remote[:group]),
               "the Leave never reached the group's origin"

        refute Follows.following?(joiner, remote[:group])
      end)
    end

    # the origin tells its followers, as `Announce{Add}`, so the mirror does not wait for its next refetch of the group
    @tag :test_instance
    test "promoting a moderator at the group's origin shows them as a moderator of a follower's mirror",
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
      assert Follows.following?(local, mirror), "control: only a follower is told"

      promoted_url =
        TestInstanceRepo.apply(fn ->
          promoted = fake_user!()

          assert {:ok, _} =
                   Bonfire.Classify.Categories.add_moderator(
                     context[:remote][:user],
                     remote[:group],
                     id(promoted)
                   )

          Bonfire.Me.Characters.character_url(promoted)
        end)

      mirrored_moderators =
        Bonfire.Classify.Categories.moderators(mirror)
        |> repo().maybe_preload(character: [:peered])
        # their AP id, since here they are a remote person
        |> Enum.map(&Bonfire.Common.URIs.canonical_url/1)

      assert promoted_url in mirrored_moderators,
             "the Announce{Add} did not reach the follower, or did not re-sync its mirror.\nmirror's moderators: #{inspect(mirrored_moderators)}"
    end

    # the moderator's decision at the origin is the only thing that can settle a pending join here, so it has to be sent back. (Was parked, its note then: "only `open_network` federates, and on the peer no stored `Join` is found to accept"; restored 17 October to see where it stands)
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
      local_url = Bonfire.Me.Characters.character_url(local)
      creator = context[:remote][:user]

      assert {:ok, mirror} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

      # by id, as the Join button does (`Bonfire.UI.Groups.LiveHandler`), which loads the group fresh
      assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(local, id(mirror))

      refute Bonfire.Classify.Categories.member?(local, mirror), "the group has not decided yet"
      assert Bonfire.Social.Requests.requested?(local, join_verb(), mirror)

      TestInstanceRepo.apply(fn ->
        joiner = on_peer(local_url)

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

    # whichever side refuses (our mirror, or the origin on receiving the Join), neither may end up with a member or a request the group never asked for. The test above is the control: the same steps for a group that reviews joins do make a request at the origin
    @tag :test_instance
    test "asking to join a remote invite-only group makes no member and no request on either side",
         context do
      remote =
        remote_group!(context, %{
          membership: "invite_only",
          visibility: "global",
          participation: "group_members",
          default_content_visibility: "public"
        })

      local = context[:local][:user]
      local_url = Bonfire.Me.Characters.character_url(local)

      assert {:ok, mirror} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

      assert Bonfire.Boundaries.Presets.group_dimension_slugs(mirror)[:membership] ==
               "invite_only",
             "control: the mirror knows it is invite-only"

      # by id, as the Join button does. Its answer isn't asserted: what matters is what each side holds after
      Bonfire.Classify.Categories.join_and_follow_group(local, id(mirror))

      refute Bonfire.Classify.Categories.member?(local, mirror)
      refute Bonfire.Social.Requests.requested?(local, join_verb(), mirror)

      TestInstanceRepo.apply(fn ->
        joiner = on_peer(local_url)

        refute Bonfire.Classify.Categories.member?(joiner, remote[:group]),
               "an invite-only group took in someone nobody invited"

        assert [] ==
                 Bonfire.Social.Requests.all_by_object(remote[:group], join_verb(),
                   skip_boundary_check: true
                 ),
               "an invite-only group got a join request it has no way to answer"
      end)
    end

    # renaming sends an actor `Update` to the group's followers, so their mirror changes without waiting for a re-fetch
    @tag :test_instance
    test "renaming a group at its origin renames a follower's mirror", context do
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
      assert Follows.following?(local, mirror), "control: only a follower is told"

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Bonfire.Classify.Categories.update(context[:remote][:user], remote[:group], %{
                   profile: %{name: "Renamed at the origin"}
                 })
      end)

      assert {:ok, mirror} =
               Bonfire.Classify.Categories.get(id(mirror), skip_boundary_check: true)

      mirror = repo().maybe_preload(mirror, :profile)

      assert mirror.profile.name == "Renamed at the origin",
             "the Update never reached the follower, so its mirror keeps the old name"
    end

    # archiving is Lemmy's community delete: a `Delete` of the group, taken back by an `Undo` of it. The follower's mirror is archived (not deleted, so the `Undo` can bring it back) and restored with it
    @tag :test_instance
    test "archiving a group at its origin archives a follower's mirror, and unarchiving restores it",
         context do
      remote =
        remote_group!(context, %{
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

      local = context[:local][:user]
      creator = context[:remote][:user]

      assert {:ok, mirror} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])
      assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(local, mirror)
      assert Follows.following?(local, mirror), "control: only a follower is told"

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} = Bonfire.Classify.Categories.soft_delete(remote[:group], creator)
      end)

      refute repo().get(Bonfire.Classify.Category, id(mirror)),
             "the Delete never reached the follower, so its mirror stays open for posts the origin closed"

      assert {:ok, %{profile: %{name: _}}} = Bonfire.Classify.Categories.get_archived(id(mirror)),
             "the mirror was deleted rather than archived, so the origin's restore can't bring it back"

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} = Bonfire.Classify.Categories.unarchive(id(remote[:group]), creator)
      end)

      assert {:ok, %{type: :group}} =
               Bonfire.Classify.Categories.get(id(mirror), skip_boundary_check: true),
             "restored at its origin, but the Undo of the Delete never restored the follower's mirror"
    end

    # a peer that doesn't follow the group is told nothing, so its mirror learns of the change on its next fetch, which re-syncs the moderators from the served collection (as Lemmy does). Promotion reaching a FOLLOWER is the test above
    @tag :test_instance
    test "a moderator removed at the group's origin is gone from a peer's mirror once it re-fetches the group",
         context do
      remote =
        remote_group!(context, %{
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

      creator = context[:remote][:user]

      {demoted, demoted_url} =
        TestInstanceRepo.apply(fn ->
          demoted = fake_user!()

          assert {:ok, _} =
                   Bonfire.Classify.Categories.add_moderator(creator, remote[:group], id(demoted))

          {demoted, Bonfire.Me.Characters.character_url(demoted)}
        end)

      assert {:ok, mirror} = AdapterUtils.get_by_url_ap_id_or_username(remote[:canonical_url])

      mirrored_moderators = fn ->
        Bonfire.Classify.Categories.moderators(mirror)
        |> repo().maybe_preload(character: [:peered])
        |> Enum.map(&Bonfire.Common.URIs.canonical_url/1)
      end

      assert demoted_url in mirrored_moderators.(),
             "control: the mirror took them as a moderator from its first fetch"

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Bonfire.Classify.Categories.remove_moderator(
                   creator,
                   remote[:group],
                   id(demoted)
                 )
      end)

      # our next fetch of it, by the AP id we hold it under
      {:ok, %{ap_id: group_ap_id}} = ActivityPub.Actor.get_cached(pointer: mirror)
      assert {:ok, _} = ActivityPub.Actor.update_actor(group_ap_id, nil, true)

      refute demoted_url in mirrored_moderators.(),
             "the re-fetch kept a moderator the origin removed, so they can still act for the group from here.\nmirror's moderators: #{inspect(mirrored_moderators.())}"
    end

    # deleting is the irreversible act, so the group's actor is served as a `Tombstone` from then on, which is what tells a peer re-fetching it that it is gone
    @tag :test_instance
    test "a group deleted at its origin is served as a Tombstone to a peer", context do
      remote =
        remote_group!(context, %{
          membership: "open",
          visibility: "global",
          participation: "anyone",
          default_content_visibility: "public"
        })

      assert {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(username: remote[:username])

      assert {:ok, %{"type" => "Group"}} =
               ActivityPub.Federator.Fetcher.fetch_remote_object_from_id(actor.ap_id,
                 return_tombstones: true
               ),
             "control: before deletion the peer is served the group"

      TestInstanceRepo.apply(fn ->
        assert {:ok, _} =
                 Bonfire.Classify.Categories.hard_delete(remote[:group],
                   current_user: context[:remote][:user]
                 )
      end)

      assert {:ok, %{"type" => "Tombstone"}} =
               ActivityPub.Federator.Fetcher.fetch_remote_object_from_id(actor.ap_id,
                 return_tombstones: true
               )
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
