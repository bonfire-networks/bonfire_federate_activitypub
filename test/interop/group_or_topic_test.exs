defmodule Bonfire.Federate.ActivityPub.GroupOrTopicTest do
  @moduledoc """
  Whether a remote `Group` is mirrored as a group or as a topic: a GROUP when people elsewhere can join it and post into it, a TOPIC when only its creator or moderators publish there, so offering "join" and "post here" would lead nowhere.

  Read from what the actor declares about itself (`Adapter.remote_declarations/1`): a topic when it says `postingRestrictedToMods: true` (PeerTube channels, WordPress blogs, Lemmy's moderator-only communities), or declares none of `attributedTo`, `openness`/`manuallyApprovesFollowers` and `postingRestrictedToMods` (Flipboard magazines). Forums that name no moderators still send `manuallyApprovesFollowers` (Hubzilla, Friendica), so they stay groups.

  Re-read on every fetch or `Update`, so a mirror follows its origin either way. And mirrors made before 23 August, which were created with no type at all (shown as topics) and with old boundaries or none (a 404 for local people), are put right the same way, on their next `Update` or by a data migration.

  One captured actor per case, hosts rewritten.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Classify.Categories
  alias Bonfire.Common.Repo

  @fixtures Path.join([__DIR__, "..", "fixtures"])

  @lemmy "https://lemmy.local/c/technology"
  @lemmy_restricted "https://lemmy.local/c/announcements"
  @peertube "https://framatube.local/video-channels/joinpeertube"
  @peertube_owner "https://framatube.local/accounts/framasoft"
  @wordpress "https://wordpress.local/@wordpress.local"
  @flipboard "https://flipboard.local/magazines/6_IpBYSbRV-7tt-Yfrp6tA:m:89340020"
  @hubzilla "https://hubzilla.local/channel/berlin"
  @friendica "https://friendica.local/profile/helpers"
  @bonfire_parent "https://bonfire.local/pub/actors/parent"
  @announcement_channel "https://bonfire.local/pub/group/announcements"
  @private_channel "https://bonfire.local/pub/group/private-channel"

  setup do
    read = fn dir, name ->
      @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()
    end

    served = %{
      @lemmy => read.("lemmy", "community_actor.json"),
      @lemmy_restricted => read.("lemmy", "community_actor_posting_restricted.json"),
      @peertube => read.("peertube", "channel_actor.json"),
      @peertube_owner =>
        Bonfire.Federate.ActivityPub.Simulate.actor_json("https://mocked.local/users/karen")
        |> Map.merge(%{
          "id" => @peertube_owner,
          "type" => "Person",
          "preferredUsername" => "framasoft",
          "inbox" => "#{@peertube_owner}/inbox",
          "outbox" => "#{@peertube_owner}/outbox"
        })
        |> put_in(["publicKey", "id"], "#{@peertube_owner}#main-key")
        |> put_in(["publicKey", "owner"], @peertube_owner),
      @wordpress => read.("wordpress", "blog_actor.json"),
      @flipboard => read.("flipboard", "magazine_actor.json"),
      @hubzilla => read.("hubzilla", "forum_actor.json"),
      @friendica => read.("friendica", "forum_actor.json"),
      # what a Bonfire announcement channel declares: public, followable by anyone, nothing to join, and only its moderators post
      @announcement_channel =>
        read.("lemmy", "community_actor.json")
        |> Map.merge(%{
          "id" => @announcement_channel,
          "preferredUsername" => "announcements",
          "inbox" => "#{@announcement_channel}/inbox",
          "outbox" => "#{@announcement_channel}/outbox",
          "followers" => "#{@announcement_channel}/followers",
          "members" => "#{@announcement_channel}/members",
          "openness" => "invite_only",
          "manuallyApprovesFollowers" => false,
          "postingRestrictedToMods" => true,
          "discoverable" => true
        })
        |> put_in(["publicKey", "id"], "#{@announcement_channel}#main-key")
        |> put_in(["publicKey", "owner"], @announcement_channel),
      # invite-only too, but following needs approval: nothing says anyone may follow it
      @private_channel =>
        read.("lemmy", "community_actor.json")
        |> Map.merge(%{
          "id" => @private_channel,
          "preferredUsername" => "private-channel",
          "inbox" => "#{@private_channel}/inbox",
          "outbox" => "#{@private_channel}/outbox",
          "followers" => "#{@private_channel}/followers",
          "members" => "#{@private_channel}/members",
          "openness" => "invite_only",
          "manuallyApprovesFollowers" => true,
          "postingRestrictedToMods" => true
        })
        |> put_in(["publicKey", "id"], "#{@private_channel}#main-key")
        |> put_in(["publicKey", "owner"], @private_channel)
    }

    mock(fn
      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    {:ok, served: served}
  end

  describe "a remote Group is mirrored as" do
    for {label, url, type} <- [
          {"a Lemmy community: a group", @lemmy, :group},
          {"a Lemmy community only its moderators post in: a topic", @lemmy_restricted, :topic},
          {"a PeerTube channel: a topic", @peertube, :topic},
          {"a WordPress blog: a topic", @wordpress, :topic},
          {"a Flipboard magazine, which declares nothing: a topic", @flipboard, :topic},
          {"a Hubzilla forum, which names no moderators but says who may follow: a group",
           @hubzilla, :group},
          {"a Friendica forum, likewise: a group", @friendica, :group}
        ] do
      test label do
        assert {:ok, %Bonfire.Classify.Category{} = mirror} =
                 Adapter.maybe_create_remote_actor(%{"id" => unquote(url)})

        assert mirror.type == unquote(type)

        # `:read` rather than `:see`: an actor declaring `discoverable: false` (the Friendica forum) is unlisted here, readable but not listed
        assert Bonfire.Boundaries.can?(fake_user!(), :read, mirror),
               "whichever it is, people here can open it"
      end
    end
  end

  # Who may follow or join a group is its origin's rule, and an invite-only group is hidden here unless it says anyone may follow it (`manuallyApprovesFollowers: false`, as our announcement channel does): then people here can open and follow it, and nobody joins
  describe "an invite-only channel is mirrored as" do
    test "a hidden group when following it needs approval" do
      assert {:ok, %Bonfire.Classify.Category{} = mirror} =
               Adapter.maybe_create_remote_actor(%{"id" => @private_channel})

      dims = Bonfire.Boundaries.Presets.group_dimension_slugs(mirror)
      assert dims[:membership] == "invite_only"

      assert dims[:visibility] != "global",
             "an invite-only group that does not say anyone may follow it is not public here"
    end

    test "a group people here can see and follow, and not join" do
      assert {:ok, %Bonfire.Classify.Category{} = mirror} =
               Adapter.maybe_create_remote_actor(%{"id" => @announcement_channel})

      dims = Bonfire.Boundaries.Presets.group_dimension_slugs(mirror)
      assert dims[:membership] == "invite_only"
      assert dims[:participation] == "moderators"

      assert dims[:visibility] == "global",
             "it is public where it lives, so it is not a hidden group here"

      user = fake_user!()
      assert Bonfire.Boundaries.can?(user, :read, mirror)
      assert {:ok, _} = Bonfire.Social.Graph.Follows.follow(user, mirror)
      refute Categories.member?(user, mirror), "following is not joining"
    end
  end

  # Our own categories say what they are, so another Bonfire mirrors a topic as a topic and a group as a group: a group declares its own `members` and `acceptsJoins` (Smithereen's `litepub:capabilities`), a topic its parent with FEP-9b2b's `broader` and `inScheme` Topic, and its parent's `members` when the parent has membership
  describe "our own categories on the wire" do
    test "a group declares its own members and that it accepts joins; a topic in it, its parent" do
      creator = fake_user!()

      group =
        Bonfire.Classify.Simulate.fake_group!(creator, %{
          membership: "open",
          visibility: "global",
          participation: "anyone"
        })

      topic = Bonfire.Classify.Simulate.fake_category!(creator, group, %{type: :topic})

      group_actor = Categories.format_actor(group).data
      topic_actor = Categories.format_actor(topic).data
      group_members = ActivityPub.Utils.collection_ap_id("members", id(group))

      assert group_actor["members"] == group_members
      assert get_in(group_actor, ["capabilities", "acceptsJoins"]) == true

      assert topic_actor["broader"] == group_actor["id"], "names its parent group"
      assert topic_actor["inScheme"] == "https://w3id.org/fep/9b2b#Topic"
      assert topic_actor["members"] == group_members, "its members are its group's"

      refute get_in(topic_actor, ["capabilities", "acceptsJoins"]),
             "a topic is followed, not joined"

      refute Map.has_key?(topic_actor, "openness"), "nobody joins a topic"
    end

    # a topic converted to a group keeps its parent here, so it is a subgroup, which names that parent as a topic does, with members of its own
    test "a subgroup names its parent group, and declares members of its own" do
      creator = fake_user!()

      group =
        Bonfire.Classify.Simulate.fake_group!(creator, %{
          membership: "open",
          visibility: "global",
          participation: "anyone"
        })

      topic = Bonfire.Classify.Simulate.fake_category!(creator, group, %{type: :topic})
      assert {:ok, subgroup} = Categories.convert(topic, :group, current_user: creator)

      group_actor = Categories.format_actor(group).data
      subgroup_actor = Categories.format_actor(subgroup).data

      assert subgroup_actor["broader"] == group_actor["id"], "names its parent group"

      assert subgroup_actor["members"] ==
               ActivityPub.Utils.collection_ap_id("members", id(subgroup)),
             "its members are its own"

      refute Map.has_key?(subgroup_actor, "inScheme"), "a group, not a topic"
    end
  end

  # what another Bonfire sends, as the test above has ours send it. A subgroup and a topic both name their `broader` group, so the parent is fetched and their `members` compared: the parent's (or none) is a topic, its own a subgroup. Either one is filed under the parent's mirror, as it is under the parent at home
  describe "a Bonfire category from another instance is mirrored as" do
    for {label, extra, type, under_parent?} <- [
          {"a topic, when it names a broader group and declares that group's members",
           %{
             "broader" => @bonfire_parent,
             "members" => "https://bonfire.local/pub/collections/members/parent"
           }, :topic, true},
          {"a topic, when it names a broader group and declares no members",
           %{"broader" => @bonfire_parent}, :topic, true},
          {"a group, when it names a broader group but has members of its own (a subgroup)",
           %{
             "broader" => @bonfire_parent,
             "members" => "https://bonfire.local/pub/collections/members/sub",
             "capabilities" => %{"acceptsJoins" => true}
           }, :group, true},
          {"a group, when nobody may post but it has members of its own (an archived group)",
           %{
             "postingRestrictedToMods" => true,
             "members" => "https://bonfire.local/pub/collections/members/archived",
             "capabilities" => %{"acceptsJoins" => true}
           }, :group, false}
        ] do
      test label, %{served: served} do
        id = "https://bonfire.local/pub/actors/#{System.unique_integer([:positive])}"
        actor = bonfire_actor(served, id, unquote(Macro.escape(extra)))
        serve_with_parent(served, id, actor)

        assert {:ok, %Bonfire.Classify.Category{} = mirror} =
                 Adapter.maybe_create_remote_actor(%{"id" => id})

        assert mirror.type == unquote(type)

        if unquote(under_parent?) do
          assert parent_id_of(mirror) == id(parent_mirror!()),
                 "filed under its parent group's mirror"
        else
          assert parent_id_of(mirror) == nil, "control: a top-level group has no parent"
        end
      end
    end

    # a mirror made from an actor that didn't name its parent (eg. before we sent `broader`) is filed under it once an `Update` does
    test "a topic is filed under its parent group's mirror once an Update names it", %{
      served: served
    } do
      id = "https://bonfire.local/pub/actors/#{System.unique_integer([:positive])}"
      before = bonfire_actor(served, id, %{"postingRestrictedToMods" => true})
      serve_with_parent(served, id, before)

      assert {:ok, %{type: :topic} = mirror} = Adapter.maybe_create_remote_actor(%{"id" => id})
      assert parent_id_of(mirror) == nil, "control: no parent named yet"

      updated = Map.put(before, "broader", @bonfire_parent)
      serve_with_parent(served, id, updated)

      assert {:ok, _} =
               ActivityPub.Federator.Transformer.handle_incoming(%{
                 "type" => "Update",
                 "id" => "#{id}/activities/update/broader",
                 "actor" => id,
                 "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                 "object" => updated
               })

      assert {:ok, reloaded} = Categories.get(id(mirror), skip_boundary_check: true)
      assert reloaded.type == :topic

      assert parent_id_of(reloaded) == id(parent_mirror!()),
             "filed under its parent group's mirror"
    end
  end

  # `broader` is what the actor's own server says about its own groups, so it is followed to a group on the actor's own host, as it is at home. A group on ANOTHER host has to agree: its own `narrower` must list the child, or any server could put its groups in that group's topic list, its sidebar and the `narrower` collection it serves, and every `Update` would put them back. One of OURS is not filed into by a remote child (our `narrower` lists only what is already filed in it)
  describe "a broader group on another host than the actor's" do
    setup do
      creator = fake_user!()

      group =
        Bonfire.Classify.Simulate.fake_group!(creator, %{
          membership: "open",
          visibility: "global",
          participation: "anyone"
        })

      {:ok,
       creator: creator, group: group, group_ap_id: Categories.format_actor(group).data["id"]}
    end

    # whether the category sits under the group in the tree, as its parent or its custodian
    defp filed_in?(category, group) do
      tree = category |> Repo.preload(:tree, force: true) |> e(:tree, nil)
      e(tree, :parent_id, nil) == id(group) or e(tree, :custodian_id, nil) == id(group)
    end

    test "ours: a mirror naming one of our groups is not filed in it", %{
      served: served,
      creator: creator,
      group: group,
      group_ap_id: group_ap_id
    } do
      local_topic = Bonfire.Classify.Simulate.fake_category!(creator, group, %{type: :topic})
      assert filed_in?(local_topic, group), "control: the probe sees a topic that is in the group"

      evil = "https://evil.local/pub/actors/#{System.unique_integer([:positive])}"
      serve(%{evil => bonfire_actor(served, evil, %{"broader" => group_ap_id})})

      assert {:ok, %Bonfire.Classify.Category{} = mirror} =
               Adapter.maybe_create_remote_actor(%{"id" => evil})

      refute filed_in?(mirror, group), "a stranger's group was filed in one of ours"
    end

    test "another host's: not filed under that group's mirror, while one on the parent's own host is",
         %{served: served} do
      n = System.unique_integer([:positive])
      parent = "https://elsewhere.local/pub/actors/parent#{n}"
      sibling = "https://elsewhere.local/pub/actors/topic#{n}"
      child = "https://bonfire.local/pub/actors/child#{n}"

      serve(%{
        parent =>
          bonfire_actor(served, parent, %{
            "members" => "#{parent}/members",
            "capabilities" => %{"acceptsJoins" => true}
          }),
        sibling => bonfire_actor(served, sibling, %{"broader" => parent}),
        child => bonfire_actor(served, child, %{"broader" => parent})
      })

      assert {:ok, sibling_mirror} = Adapter.maybe_create_remote_actor(%{"id" => sibling})

      assert {:ok, parent_mirror} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(parent)

      assert parent_id_of(sibling_mirror) == id(parent_mirror),
             "control: on the parent's own host, it is filed under it"

      assert {:ok, mirror} = Adapter.maybe_create_remote_actor(%{"id" => child})
      assert parent_id_of(mirror) == nil, "filed under a group on another host"
    end

    # a parent on another host that lists the child in its own `narrower` has agreed to it
    defp listing(narrower, items) do
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => narrower,
        "type" => "Collection",
        "totalItems" => length(items),
        "items" => items
      }
    end

    defp elsewhere_parent(served, parent, narrower) do
      bonfire_actor(served, parent, %{
        "members" => "#{parent}/members",
        "capabilities" => %{"acceptsJoins" => true},
        "narrower" => narrower
      })
    end

    test "another host's that lists the child: filed under that group's mirror, and not one that doesn't list it",
         %{served: served} do
      n = System.unique_integer([:positive])
      parent = "https://elsewhere.local/pub/actors/parent#{n}"
      narrower = "#{parent}/narrower"
      child = "https://bonfire.local/pub/actors/child#{n}"
      unlisted = "https://bonfire.local/pub/actors/unlisted#{n}"

      serve(%{
        parent => elsewhere_parent(served, parent, narrower),
        narrower => listing(narrower, [child]),
        child => bonfire_actor(served, child, %{"broader" => parent}),
        unlisted => bonfire_actor(served, unlisted, %{"broader" => parent})
      })

      assert {:ok, mirror} = Adapter.maybe_create_remote_actor(%{"id" => child})

      assert {:ok, parent_mirror} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(parent)

      assert parent_id_of(mirror) == id(parent_mirror), "listed by the parent, so filed in it"

      # control: the same parent, naming a child it doesn't list
      assert {:ok, unlisted_mirror} = Adapter.maybe_create_remote_actor(%{"id" => unlisted})
      assert parent_id_of(unlisted_mirror) == nil, "not listed by the parent, so not filed in it"
    end

    # a topic shares its parent's members collection, which is how it is told from a subgroup with members of its own; a parent that doesn't list it is still read for that, but not mirrored for it (it stays a topic, at the top level)
    test "a topic naming another host's group that doesn't list it stays a topic, and that group isn't mirrored for it",
         %{served: served} do
      n = System.unique_integer([:positive])
      parent = "https://elsewhere.local/pub/actors/parent#{n}"
      narrower = "#{parent}/narrower"
      child = "https://bonfire.local/pub/actors/child#{n}"

      serve(%{
        parent => elsewhere_parent(served, parent, narrower),
        narrower => listing(narrower, []),
        child =>
          bonfire_actor(served, child, %{"broader" => parent, "members" => "#{parent}/members"})
      })

      assert {:ok, %{type: :topic} = mirror} = Adapter.maybe_create_remote_actor(%{"id" => child})
      assert parent_id_of(mirror) == nil, "control: not listed, so not filed"

      assert {:error, :not_found} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(parent),
             "a group that didn't agree to the child was mirrored for it"
    end

    test "an Update naming another host's group that lists it moves the mirror there", %{
      served: served
    } do
      n = System.unique_integer([:positive])
      id = "https://bonfire.local/pub/actors/#{n}"
      parent = "https://elsewhere.local/pub/actors/parent#{n}"
      narrower = "#{parent}/narrower"
      before = bonfire_actor(served, id, %{"broader" => @bonfire_parent})
      serve_with_parent(served, id, before)

      assert {:ok, mirror} = Adapter.maybe_create_remote_actor(%{"id" => id})
      assert parent_id_of(mirror) == id(parent_mirror!()), "control: under its own host's group"

      updated = Map.put(before, "broader", parent)

      serve(%{
        id => updated,
        parent => elsewhere_parent(served, parent, narrower),
        narrower => listing(narrower, [id])
      })

      assert {:ok, _} =
               ActivityPub.Federator.Transformer.handle_incoming(%{
                 "type" => "Update",
                 "id" => "#{id}/activities/update/moved",
                 "actor" => id,
                 "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                 "object" => updated
               })

      assert {:ok, parent_mirror} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(parent)

      assert {:ok, reloaded} = Categories.get(id(mirror), skip_boundary_check: true)
      assert parent_id_of(reloaded) == id(parent_mirror)
    end

    # one filed in one of ours before that was refused stays there until its next Update, which takes it out (no data migration)
    test "a mirror filed in one of ours before is taken out on its next Update", %{
      served: served,
      group: group,
      group_ap_id: group_ap_id
    } do
      evil = "https://evil.local/pub/actors/#{System.unique_integer([:positive])}"
      actor = bonfire_actor(served, evil, %{"broader" => group_ap_id})
      serve(%{evil => actor})

      assert {:ok, mirror} = Adapter.maybe_create_remote_actor(%{"id" => evil})

      # as it could have been filed before: straight into the tree
      mirror = Repo.preload(mirror, :tree, force: true)
      if mirror.tree, do: Repo.delete!(mirror.tree)

      Bonfire.Classify.Tree.changeset(%Bonfire.Classify.Tree{id: id(mirror)}, %{
        parent: group,
        custodian_id: id(group)
      })
      |> Repo.insert!()

      assert filed_in?(mirror, group), "control: filed in ours, as before the fix"

      # its next Update, which changes something (an unchanged actor document is not re-applied)
      updated = Map.put(actor, "summary", "edited #{System.unique_integer([:positive])}")
      serve(%{evil => updated})

      assert {:ok, _} =
               ActivityPub.Federator.Transformer.handle_incoming(%{
                 "type" => "Update",
                 "id" => "#{evil}/activities/update/again",
                 "actor" => evil,
                 "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                 "object" => updated
               })

      refute filed_in?(mirror, group), "still in one of ours after its Update"
    end

    test "an Update naming one of ours doesn't move a mirror out of its parent", %{
      served: served,
      group: group,
      group_ap_id: group_ap_id
    } do
      id = "https://bonfire.local/pub/actors/#{System.unique_integer([:positive])}"
      before = bonfire_actor(served, id, %{"broader" => @bonfire_parent})
      serve_with_parent(served, id, before)

      assert {:ok, mirror} = Adapter.maybe_create_remote_actor(%{"id" => id})

      assert parent_id_of(mirror) == id(parent_mirror!()),
             "control: filed under its own host's group"

      updated = Map.put(before, "broader", group_ap_id)
      serve_with_parent(served, id, updated)

      assert {:ok, _} =
               ActivityPub.Federator.Transformer.handle_incoming(%{
                 "type" => "Update",
                 "id" => "#{id}/activities/update/hijack",
                 "actor" => id,
                 "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                 "object" => updated
               })

      assert {:ok, reloaded} = Categories.get(id(mirror), skip_boundary_check: true)
      assert parent_id_of(reloaded) == id(parent_mirror!())
      refute filed_in?(reloaded, group)
    end
  end

  # a parent may name a parent in turn, and a chain may be a cycle (FEP-9b2b: "limit how far you follow them"), so the chain is followed as deep as incoming threads may be (`federation_incoming_max_recursion`) and a cycle isn't followed round
  describe "a chain of broader groups" do
    setup %{served: served} do
      [group, subgroup, topic] =
        for name <- ~w(group subgroup topic),
            do: "https://bonfire.local/pub/actors/#{name}#{System.unique_integer([:positive])}"

      serve(%{
        group =>
          bonfire_actor(served, group, %{
            "members" => "#{group}/members",
            "capabilities" => %{"acceptsJoins" => true}
          }),
        subgroup =>
          bonfire_actor(served, subgroup, %{
            "broader" => group,
            "members" => "#{subgroup}/members",
            "capabilities" => %{"acceptsJoins" => true}
          }),
        topic => bonfire_actor(served, topic, %{"broader" => subgroup})
      })

      {:ok, group: group, subgroup: subgroup, topic: topic}
    end

    test "is followed: a topic in a subgroup in a group is filed at every level", ctx do
      assert {:ok, %{type: :topic} = topic} =
               Adapter.maybe_create_remote_actor(%{"id" => ctx.topic})

      assert {:ok, %{type: :group} = subgroup} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.subgroup)

      assert {:ok, %{type: :group} = group} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.group)

      assert parent_id_of(topic) == id(subgroup), "the topic in its subgroup"
      assert parent_id_of(subgroup) == id(group), "the subgroup in its group"
      assert parent_id_of(group) == nil, "control: the group is top-level"
    end

    test "is followed no deeper than incoming threads may be", ctx do
      previous = ActivityPub.Config.get([:instance, :federation_incoming_max_recursion])
      ActivityPub.Config.put([:instance, :federation_incoming_max_recursion], 0)

      on_exit(fn ->
        ActivityPub.Config.put([:instance, :federation_incoming_max_recursion], previous)
      end)

      assert {:ok, %{type: :topic} = topic} =
               Adapter.maybe_create_remote_actor(%{"id" => ctx.topic})

      assert parent_id_of(topic) == nil, "no parent followed at a limit of 0"
    end

    # the parent is made before the child's transaction opens (`AdapterUtils.create_remote_actor/1` → `Categories.remote_parent/2`), so a parent the database refuses can't abort the child's: here a NUL byte, which Postgres refuses in `text` and `jsonb` alike
    test "whose parent can't be made still mirrors the child, at the top level", %{served: served} do
      [parent, topic] =
        for name <- ~w(parent topic),
            do: "https://bonfire.local/pub/actors/#{name}#{System.unique_integer([:positive])}"

      serve(%{
        parent =>
          bonfire_actor(served, parent, %{
            "preferredUsername" => "broken\u0000parent",
            "members" => "#{parent}/members",
            "capabilities" => %{"acceptsJoins" => true}
          }),
        topic => bonfire_actor(served, topic, %{"broader" => parent})
      })

      assert {:ok, %{type: :topic} = mirror} = Adapter.maybe_create_remote_actor(%{"id" => topic})

      assert {:error, :not_found} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(parent),
             "control: the parent really couldn't be made"

      assert parent_id_of(mirror) == nil, "filed nowhere until its parent can be made"
    end

    test "that is a cycle is mirrored once each, and not followed round", %{served: served} do
      [a, b] =
        for name <- ~w(a b),
            do: "https://bonfire.local/pub/actors/#{name}#{System.unique_integer([:positive])}"

      serve(%{
        a =>
          bonfire_actor(served, a, %{
            "broader" => b,
            "members" => "#{a}/members",
            "capabilities" => %{"acceptsJoins" => true}
          }),
        b =>
          bonfire_actor(served, b, %{
            "broader" => a,
            "members" => "#{b}/members",
            "capabilities" => %{"acceptsJoins" => true}
          })
      })

      assert {:ok, %{type: :group} = a_mirror} = Adapter.maybe_create_remote_actor(%{"id" => a})

      assert {:ok, b_mirror} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(b)

      assert parent_id_of(a_mirror) == id(b_mirror), "the first one in the group it names"
      assert parent_id_of(b_mirror) == nil, "the other not filed back under the first"
    end
  end

  # A group lists its topics and subgroups in a `narrower` collection, so the children nobody here has met yet are mirrored and filed under its mirror. Fetched as the AP library fetches replies (the collection, then each entry, by jobs, which tests run inline), as many as it fetches of any collection (`federation_incoming_max_items`), as FEP-9b2b asks of consumers. Each one is filed under the group it names itself, so one listed that names another group is mirrored, as any actor we fetch is, but not filed here
  describe "a group's narrower collection" do
    setup %{served: served} do
      group = "https://bonfire.local/pub/actors/group#{System.unique_integer([:positive])}"
      narrower = "#{group}/narrower"

      [topic, subgroup, stranger] =
        for name <- ~w(topic subgroup stranger),
            do: "https://bonfire.local/pub/actors/#{name}#{System.unique_integer([:positive])}"

      actors = %{
        group =>
          bonfire_actor(served, group, %{
            "members" => "#{group}/members",
            "capabilities" => %{"acceptsJoins" => true},
            "narrower" => narrower
          }),
        topic => bonfire_actor(served, topic, %{"broader" => group}),
        subgroup =>
          bonfire_actor(served, subgroup, %{
            "broader" => group,
            "members" => "#{subgroup}/members",
            "capabilities" => %{"acceptsJoins" => true}
          }),
        # listed, but in no group of this one's
        stranger => bonfire_actor(served, stranger, %{"postingRestrictedToMods" => true})
      }

      {:ok,
       actors: actors,
       group: group,
       narrower: narrower,
       topic: topic,
       subgroup: subgroup,
       stranger: stranger}
    end

    defp serve_narrower(ctx, items) do
      serve(
        Map.put(ctx.actors, ctx.narrower, %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => ctx.narrower,
          "type" => "Collection",
          "totalItems" => length(items),
          "items" => items
        })
      )
    end

    test "mirrors the children listed, under the group's mirror, and doesn't file an actor in another group there",
         ctx do
      serve_narrower(ctx, [ctx.topic, ctx.subgroup, ctx.stranger])

      assert {:ok, %{type: :group} = group} =
               Adapter.maybe_create_remote_actor(%{"id" => ctx.group})

      assert {:ok, _} = Categories.sync_remote_children(group)
      # the fetches are jobs, which tests run when asked
      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, %{type: :topic} = topic} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.topic)

      assert {:ok, %{type: :group} = subgroup} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.subgroup)

      assert parent_id_of(topic) == id(group)
      assert parent_id_of(subgroup) == id(group)

      # mirrored or not, as any actor we fetch may be
      case Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.stranger) do
        {:ok, stranger} ->
          refute parent_id_of(stranger) == id(group),
                 "an actor that doesn't name this group as its parent isn't filed under it"

        _ ->
          :ok
      end
    end

    # the other way round: a group lists a child on another host that names it back, so both sides agree, and the child is filed under it
    test "files a child on another host that names the group back", %{served: served} do
      n = System.unique_integer([:positive])
      group = "https://elsewhere.local/pub/actors/group#{n}"
      narrower = "#{group}/narrower"
      child = "https://bonfire.local/pub/actors/child#{n}"
      stranger = "https://bonfire.local/pub/actors/stranger#{n}"

      serve(%{
        group =>
          bonfire_actor(served, group, %{
            "members" => "#{group}/members",
            "capabilities" => %{"acceptsJoins" => true},
            "narrower" => narrower
          }),
        narrower => %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => narrower,
          "type" => "Collection",
          "totalItems" => 2,
          "items" => [child, stranger]
        },
        child => bonfire_actor(served, child, %{"broader" => group}),
        # listed, but naming no group
        stranger => bonfire_actor(served, stranger, %{"postingRestrictedToMods" => true})
      })

      assert {:ok, group_mirror} = Adapter.maybe_create_remote_actor(%{"id" => group})
      assert {:ok, _} = Categories.sync_remote_children(group_mirror)
      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, child_mirror} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(child)

      assert parent_id_of(child_mirror) == id(group_mirror)

      # control: listed, but it doesn't name the group, so it isn't filed there
      case Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(stranger) do
        {:ok, stranger_mirror} -> refute parent_id_of(stranger_mirror) == id(group_mirror)
        _ -> :ok
      end
    end

    # the AP library's limit on any collection it fetches, which counts the collection itself: at 2, the collection and its first entry
    test "mirrors no more than the AP library fetches of a collection", ctx do
      previous = ActivityPub.Config.get([:instance, :federation_incoming_max_items])
      ActivityPub.Config.put([:instance, :federation_incoming_max_items], 2)

      on_exit(fn ->
        ActivityPub.Config.put([:instance, :federation_incoming_max_items], previous)
      end)

      serve_narrower(ctx, [ctx.topic, ctx.subgroup])

      assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => ctx.group})
      assert {:ok, _} = Categories.sync_remote_children(group)
      # the fetches are jobs, which tests run when asked
      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      mirrored =
        for ap_id <- [ctx.topic, ctx.subgroup],
            match?(
              {:ok, _},
              Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ap_id)
            ),
            do: ap_id

      assert mirrored == [ctx.topic], "only the first of the list"
    end

    # making the mirror is one of the triggers (`update_remote_actor/2`, after the transaction that makes it, so the jobs see it), and once per `children_sync_interval`
    test "is synced once the mirror is made, and not again soon after", ctx do
      serve_narrower(ctx, [ctx.topic])

      assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => ctx.group})
      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, topic} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.topic),
             "the listed topic is mirrored without being asked for"

      assert parent_id_of(topic) == id(group)

      assert :skip == Categories.maybe_sync_remote_children(group),
             "not again within the interval"
    end

    # a mirror made before groups declared `narrower` is fetched again to catch up, but Lemmy, PieFed and Mbin groups never declare it, and an actor just fetched to make its mirror is as fresh as it gets
    test "a group that lists no topics, as Lemmy's don't, is fetched once to mirror it, and not again when someone here joins",
         %{served: served} do
      me = self()

      mock(fn
        %{method: :get, url: url} ->
          send(me, {:fetched, url})

          case served[url] do
            nil -> %Tesla.Env{status: 404, body: ""}
            body -> json(body)
          end

        %{method: :post} ->
          %Tesla.Env{status: 202, body: ""}
      end)

      assert {:ok, %{type: :group} = group} = Adapter.maybe_create_remote_actor(%{"id" => @lemmy})
      assert fetches_of(@lemmy) == 1, "fetched once, to mirror it"

      assert {:ok, _} = Categories.join_and_follow_group(fake_user!(), id(group))
      assert fetches_of(@lemmy) == 0, "not fetched again when someone here joins"
    end

    defp fetches_of(url, count \\ 0) do
      receive do
        {:fetched, ^url} -> fetches_of(url, count + 1)
      after
        0 -> count
      end
    end

    # as search and the groups page look a group up (`Bonfire.Search.LiveHandler`, `Bonfire.UI.Groups.ExploreLive`), with the AP caches on as in prod
    test "a group found by its URL has its topics mirrored, with the AP cache on", ctx do
      ap_cache_on()
      serve_narrower(ctx, [ctx.topic])
      searcher = fake_user!()

      assert {:ok, %{type: :group} = group} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
                 ctx.group,
                 user_id: id(searcher)
               )

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, topic} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.topic),
             "the listed topic is mirrored"

      assert parent_id_of(topic) == id(group)
    end

    # as Bonfire serves its `narrower`: the collection links its first page, which holds the items
    test "a group whose collection is served in pages has its topics mirrored when it's found",
         ctx do
      ap_cache_on()
      page = "#{ctx.narrower}?page=1"

      serve(
        ctx.actors
        |> Map.put(ctx.narrower, %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => ctx.narrower,
          "type" => "OrderedCollection",
          "totalItems" => 1,
          "first" => page
        })
        |> Map.put(page, %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => page,
          "type" => "OrderedCollectionPage",
          "partOf" => ctx.narrower,
          "orderedItems" => [ctx.topic]
        })
      )

      assert {:ok, %{type: :group} = group} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
                 ctx.group,
                 user_id: id(fake_user!())
               )

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, topic} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.topic),
             "the topic on the collection's first page is mirrored"

      assert parent_id_of(topic) == id(group)
    end

    # joining is a trigger too (`join_group/3`, and `follow_group/3`, which pressing Join also calls): it must still mirror the topics when the sync made with the mirror got none, as when the collection couldn't be read then, and someone joins within the `children_sync_interval`
    test "a group someone here joins has its topics mirrored, when the sync made with its mirror got none",
         ctx do
      assert_join_mirrors_topics(ctx, ctx.actors)
    end

    test "a group someone here asks to join has its topics mirrored, when the sync made with its mirror got none",
         ctx do
      actors =
        Map.update!(ctx.actors, ctx.group, &Map.put(&1, "openness", "moderated"))

      assert_join_mirrors_topics(ctx, actors)
    end

    defp assert_join_mirrors_topics(ctx, actors) do
      ap_cache_on()

      # the 404 below is remembered for `[:activity_pub, :fetch_error_cache_ttl]` (a minute by default) and not fetched again in that time, and someone joins later than that: a few ms here
      fetch_error_cache_ttl(5)
      # the collection can't be read yet: a 404
      serve(actors)

      assert {:ok, %{type: :group} = group} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_by_url_ap_id_or_username(
                 ctx.group,
                 user_id: id(fake_user!())
               )

      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:error, :not_found} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.topic),
             "control: nothing was mirrored when the mirror was made"

      # and now it can be read
      serve_narrower(%{ctx | actors: actors}, [ctx.topic])
      # the 404 is no longer remembered by the time someone joins
      Process.sleep(10)

      assert {:ok, joined} = Categories.join_and_follow_group(fake_user!(), id(group))
      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:ok, topic} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.topic),
             "the listed topic is mirrored once someone joins (#{inspect(joined)})"

      assert parent_id_of(topic) == id(group)
    end

    # tests bypass the AP caches by default, where prod has them on
    defp ap_cache_on do
      Process.put(:activity_pub_enable_cache, true)
      ActivityPub.Utils.cache_clear()
      on_exit(fn -> ActivityPub.Utils.cache_clear() end)
    end

    defp fetch_error_cache_ttl(ttl) do
      previous = Application.get_env(:activity_pub, :fetch_error_cache_ttl)
      Application.put_env(:activity_pub, :fetch_error_cache_ttl, ttl)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:activity_pub, :fetch_error_cache_ttl, previous),
          else: Application.delete_env(:activity_pub, :fetch_error_cache_ttl)
      end)
    end

    test "isn't synced for a local group", %{served: _served} do
      group = Bonfire.Classify.Simulate.fake_group!(fake_user!())
      assert :skip == Categories.maybe_sync_remote_children(group)
    end

    test "leaves the mirror as it is when the collection can't be read", ctx do
      # the collection isn't served: a 404
      serve(ctx.actors)

      assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => ctx.group})
      assert {:ok, _} = Categories.sync_remote_children(group)
      # the fetches are jobs, which tests run when asked
      Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

      assert {:error, :not_found} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.topic)
    end
  end

  # A handle is hashed with its underscores dropped and look-alikes folded (`Character.hash/1`), so `jan_beta` and `janbeta` on one instance are two accounts to PeerTube and one to us. Seen on bonfire.cafe: the second, a moderator of mirrors being repaired, RAISED out of `create_remote_actor/1` (the unique index refuses the insert, and the failed insert aborts the transaction around it) and ended the repair of every mirror listing it
  describe "a moderator whose handle folds to one already taken" do
    # the group's moderators list (`moderators`) is NOT served here: each test serves it when it needs it, since a collection already fetched may be cached and so would not change
    setup %{served: served} do
      [group, taken, folded, other] =
        for name <- ~w(group janbeta jan_beta other),
            do: "https://bonfire.local/pub/actors/#{name}#{System.unique_integer([:positive])}"

      moderators = "#{group}/moderators"

      actors = %{
        group =>
          bonfire_actor(served, group, %{
            "members" => "#{group}/members",
            "capabilities" => %{"acceptsJoins" => true},
            "attributedTo" => moderators
          }),
        taken => person_actor(taken, "janbeta"),
        folded => person_actor(folded, "jan_beta"),
        other => person_actor(other, "other_mod")
      }

      serve(actors)

      # the account whose handle is held first, as on cafe
      assert {:ok, taken_mirror} = Adapter.maybe_create_remote_actor(%{"id" => taken})

      {:ok,
       actors: actors,
       group: group,
       moderators: moderators,
       taken: taken,
       taken_mirror: taken_mirror,
       folded: folded,
       other: other}
    end

    defp serve_moderators(ctx, items) do
      serve(
        Map.put(ctx.actors, ctx.moderators, %{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => ctx.moderators,
          "type" => "Collection",
          "totalItems" => length(items),
          "items" => items
        })
      )
    end

    test "is skipped, and a new group is mirrored with its other moderators", ctx do
      serve_moderators(ctx, [ctx.taken, ctx.folded, ctx.other])

      assert {:ok, %{type: :group} = mirror} =
               Adapter.maybe_create_remote_actor(%{"id" => ctx.group})

      assert {:error, _} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.folded),
             "control: the folded one wasn't mirrored (its handle is taken)"

      assert {:ok, other_mirror} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.other)

      moderator_ids = Categories.moderators(mirror) |> Enum.map(&id/1)
      assert id(other_mirror) in moderator_ids, "its other moderators are still added"
      assert id(ctx.taken_mirror) in moderator_ids
    end

    # the path the cafe repair takes: a mirror already there, whose moderators are read again, outside any transaction of the group's own
    test "is skipped on an Update of a group already mirrored", ctx do
      # first mirrored while its moderators list is down (a 404), as an origin sometimes is
      assert {:ok, %{type: :group} = mirror} =
               Adapter.maybe_create_remote_actor(%{"id" => ctx.group})

      assert {:error, _} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.other),
             "control: no moderator was mirrored yet, so the list is read by the Update"

      # an `Update` is re-fetched from its origin rather than trusted, and an actor re-fetched unchanged doesn't reach the adapter, so it is served changed
      updated = Map.put(ctx.actors[ctx.group], "summary", "<p>changed since</p>")

      serve_moderators(
        %{ctx | actors: Map.put(ctx.actors, ctx.group, updated)},
        [ctx.taken, ctx.folded, ctx.other]
      )

      assert {:ok, _} =
               ActivityPub.Federator.Transformer.handle_incoming(%{
                 "type" => "Update",
                 "id" => "#{ctx.group}/activities/update/moderators",
                 "actor" => ctx.group,
                 "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                 "object" => updated
               })

      assert {:ok, other_mirror} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.other)

      assert id(other_mirror) in (Categories.moderators(mirror) |> Enum.map(&id/1))

      assert {:error, _} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.folded)
    end

    # what stopped bonfire.cafe's repair: the mirror stays untyped while a moderator in its list can't be made
    test "doesn't leave an untyped mirror untyped when the data migration repairs it", ctx do
      assert {:ok, %{type: :group} = mirror} =
               Adapter.maybe_create_remote_actor(%{"id" => ctx.group})

      # back to the old shape, as in "a mirror made before 23 August"
      Repo.update_all(
        from(c in Bonfire.Classify.Category, where: c.id == ^id(mirror)),
        set: [type: nil]
      )

      Repo.delete_all(
        from(c in Bonfire.Data.AccessControl.Controlled, where: c.id == ^id(mirror))
      )

      assert {:ok, %{type: nil}} = Categories.get(id(mirror), skip_boundary_check: true),
             "control: the old shape"

      serve_moderators(ctx, [ctx.taken, ctx.folded, ctx.other])

      Bonfire.Classify.UntypedMirrors.DataMigration.migrate([%{id: id(mirror)}])

      assert {:ok, %{type: :group}} = Categories.get(id(mirror), skip_boundary_check: true),
             "the repair stopped at the moderator whose handle is taken"

      assert {:ok, other_mirror} =
               Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(ctx.other)

      assert id(other_mirror) in (Categories.moderators(mirror) |> Enum.map(&id/1))
    end
  end

  defp person_actor(id, username) do
    Bonfire.Federate.ActivityPub.Simulate.actor_json("https://mocked.local/users/karen")
    |> Map.merge(%{
      "id" => id,
      "type" => "Person",
      "preferredUsername" => username,
      "inbox" => "#{id}/inbox",
      "outbox" => "#{id}/outbox"
    })
    |> put_in(["publicKey", "id"], "#{id}#main-key")
    |> put_in(["publicKey", "owner"], id)
  end

  # an actor as another Bonfire serves one, built on the Lemmy capture
  defp bonfire_actor(served, id, extra) do
    served[@lemmy]
    |> Map.drop(["postingRestrictedToMods"])
    |> Map.merge(%{
      "id" => id,
      "preferredUsername" => "cat#{System.unique_integer([:positive])}",
      "inbox" => "#{id}/inbox",
      "outbox" => "#{id}/outbox",
      "followers" => "#{id}/followers",
      "attributedTo" => "#{id}/moderators"
    })
    |> Map.merge(extra)
    |> put_in(["publicKey", "id"], "#{id}#main-key")
    |> put_in(["publicKey", "owner"], id)
  end

  # serves `actor` at `id`, and the group it may name as its parent at `@bonfire_parent`
  defp serve_with_parent(served, id, actor) do
    parent =
      bonfire_actor(served, @bonfire_parent, %{
        "members" => "https://bonfire.local/pub/collections/members/parent",
        "capabilities" => %{"acceptsJoins" => true}
      })

    mock(fn
      %{method: :get, url: ^id} -> json(actor)
      %{method: :get, url: @bonfire_parent} -> json(parent)
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
    end)
  end

  # serves each actor at its id
  defp serve(actors) do
    mock(fn
      %{method: :get, url: url} ->
        case actors[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          actor -> json(actor)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)
  end

  defp parent_mirror! do
    assert {:ok, parent} =
             Bonfire.Federate.ActivityPub.AdapterUtils.get_character_by_ap_id(@bonfire_parent)

    parent
  end

  defp parent_id_of(category) do
    category |> Repo.preload(:tree, force: true) |> e(:tree, :parent_id, nil)
  end

  # Smithereen's (and our) `capabilities.acceptsJoins` says people join it, which the fork reads into `openness` when nothing more specific says (`Transformer.fix_openness/1`)
  test "a group that only says it accepts joins is mirrored as open to join", %{served: served} do
    id = "https://smithereen.local/groups/1"

    actor =
      served[@lemmy]
      |> Map.drop(["postingRestrictedToMods", "attributedTo", "manuallyApprovesFollowers"])
      |> Map.merge(%{
        "id" => id,
        "preferredUsername" => "joinable",
        "inbox" => "#{id}/inbox",
        "outbox" => "#{id}/outbox",
        "followers" => "#{id}/followers",
        "members" => "#{id}/members",
        "capabilities" => %{"acceptsJoins" => true}
      })
      |> put_in(["publicKey", "id"], "#{id}#main-key")
      |> put_in(["publicKey", "owner"], id)

    mock(fn
      %{method: :get, url: ^id} -> json(actor)
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
    end)

    assert {:ok, %{type: :group} = mirror} = Adapter.maybe_create_remote_actor(%{"id" => id})

    assert {:ok, %{data: %{"openness" => "open"}}} = ActivityPub.Actor.get_cached(ap_id: id)
    assert Bonfire.Boundaries.Presets.group_dimension_slugs(mirror)[:membership] == "open"
  end

  describe "re-read on every Update" do
    test "a community that starts restricting posting to its moderators becomes a topic, and a group again when it stops, its follows kept",
         %{served: served} do
      assert {:ok, %{type: :group} = mirror} =
               Adapter.maybe_create_remote_actor(%{"id" => @lemmy})

      follower = fake_user!()
      assert {:ok, _} = Bonfire.Social.Graph.Follows.follow(follower, mirror)

      # following a group elsewhere is a request until its origin `Accept`s it, which nothing does here, so compare whatever state it is in
      follow_state = fn category ->
        {Bonfire.Social.Graph.Follows.following?(follower, category),
         Bonfire.Social.Graph.Follows.requested?(follower, category)}
      end

      follow_before = follow_state.(mirror)
      assert follow_before != {false, false}, "control: the follow was made"

      for {restricted?, type} <- [{true, :topic}, {false, :group}] do
        updated = Map.put(served[@lemmy], "postingRestrictedToMods", restricted?)

        # the origin now serves the changed actor: an `Update`'s own payload is not trusted, the actor is re-fetched from where it lives (`Transformer.handle_incoming/2` for actors)
        mock(fn
          %{method: :get, url: @lemmy} ->
            json(updated)

          %{method: :get, url: url} ->
            case served[url] do
              nil -> %Tesla.Env{status: 404, body: ""}
              body -> json(body)
            end

          %{method: :post} ->
            %Tesla.Env{status: 202, body: ""}
        end)

        assert {:ok, _} =
                 ActivityPub.Federator.Transformer.handle_incoming(%{
                   "type" => "Update",
                   "id" => "#{@lemmy}/activities/update/#{restricted?}",
                   "actor" => @lemmy,
                   "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                   "object" => updated
                 })

        assert {:ok, reloaded} = Categories.get(id(mirror), skip_boundary_check: true)
        assert reloaded.type == type, "postingRestrictedToMods: #{restricted?}"

        assert follow_state.(reloaded) == follow_before, "the follow carries over"
      end
    end
  end

  # Before 23 August, `Categories.create_remote/2` set no type, so those mirrors are topics, and their boundaries are whatever the code of the day gave them: none (knitting@lemmy.world on bonfire.cafe, a 404) or the public preset (fuckcars@lemmy.world, visible but a topic). Reproduced here by taking a mirror back to either shape
  describe "a mirror made before 23 August" do
    setup do
      {:ok, mirror} = Adapter.maybe_create_remote_actor(%{"id" => @lemmy})

      untyped = fn acl_ids ->
        Repo.update_all(
          from(c in Bonfire.Classify.Category, where: c.id == ^id(mirror)),
          set: [type: nil]
        )

        Repo.delete_all(
          from(c in Bonfire.Data.AccessControl.Controlled, where: c.id == ^id(mirror))
        )

        if acl_ids != [], do: Bonfire.Boundaries.Controlleds.add_acls(id(mirror), acl_ids)
        :ok
      end

      {:ok, mirror: mirror, untyped: untyped}
    end

    for {shape, acl_ids} <- [
          {"with no boundaries", []},
          {"with the public preset's",
           [
             "5REM0TEPE0P1E1NTERACTREP1Y",
             "710CA1SMY1NTERACTANDREP1YY",
             "7W1DE1YAVA11AB1ET0SEENREAD"
           ]}
        ] do
      test "#{shape} is a group again after its next Update", %{
        mirror: mirror,
        untyped: untyped,
        served: served
      } do
        untyped.(unquote(acl_ids))

        assert {:ok, %{type: nil}} = Categories.get(id(mirror), skip_boundary_check: true),
               "control: the old shape"

        # an `Update` is sent when the actor changed, and is re-fetched from its origin rather than trusted, which here serves it changed (an actor re-fetched unchanged doesn't reach the adapter, so for those it's the data migration that repairs them)
        updated = Map.put(served[@lemmy], "summary", "<p>changed since</p>")

        mock(fn
          %{method: :get, url: @lemmy} ->
            json(updated)

          %{method: :get, url: url} ->
            case served[url] do
              nil -> %Tesla.Env{status: 404, body: ""}
              body -> json(body)
            end

          %{method: :post} ->
            %Tesla.Env{status: 202, body: ""}
        end)

        assert {:ok, _} =
                 ActivityPub.Federator.Transformer.handle_incoming(%{
                   "type" => "Update",
                   "id" => "#{@lemmy}/activities/update/repair",
                   "actor" => @lemmy,
                   "to" => ["https://www.w3.org/ns/activitystreams#Public"],
                   "object" => updated
                 })

        assert {:ok, %{type: :group} = repaired} =
                 Categories.get(id(mirror), skip_boundary_check: true)

        assert Bonfire.Boundaries.can?(fake_user!(), :read, repaired),
               "people here can open it"

        assert Bonfire.Boundaries.Presets.group_dimension_slugs(repaired)[:membership] == "open",
               "as its actor declares"
      end

      test "#{shape} is a group again after the data migration", %{
        mirror: mirror,
        untyped: untyped
      } do
        untyped.(unquote(acl_ids))

        assert {:ok, %{type: nil}} = Categories.get(id(mirror), skip_boundary_check: true),
               "control: the old shape"

        Bonfire.Classify.UntypedMirrors.DataMigration.migrate([%{id: id(mirror)}])

        assert {:ok, %{type: :group} = repaired} =
                 Categories.get(id(mirror), skip_boundary_check: true)

        assert Bonfire.Boundaries.can?(fake_user!(), :read, repaired)
      end
    end

    # A batch's mirrors are repaired one after another, so one whose repair raises must not lose the rest of its batch. Seen on bonfire.cafe (18 October, 2507 still untyped after the migration ran): repairing a mirror syncs its moderators, and creating one of them (`jan_beta@makertube.net`) collided with `janbeta@makertube.net`, whose hash it shares (underscores are dropped), so its transaction rolled back and the raise ended the run. That collision is covered by "a moderator whose handle folds to one already taken"; this stands in an entry whose repair raises for certain
    test "the data migration goes on past a mirror whose repair raises", %{
      mirror: mirror,
      untyped: untyped
    } do
      untyped.([])

      assert {:ok, %{type: nil}} = Categories.get(id(mirror), skip_boundary_check: true),
             "control: the old shape"

      Bonfire.Classify.UntypedMirrors.DataMigration.migrate([:not_a_row, %{id: id(mirror)}])

      assert {:ok, %{type: :group}} = Categories.get(id(mirror), skip_boundary_check: true),
             "the mirror after one whose repair raised was never repaired"
    end

    test "a mirror that already has a type is left as it is", %{mirror: mirror} do
      assert {:ok, %{type: :group}} = Categories.get(id(mirror), skip_boundary_check: true)

      acls_before =
        Bonfire.Boundaries.Controlleds.list_on_object(id(mirror)) |> Enum.map(& &1.acl_id)

      Bonfire.Classify.UntypedMirrors.DataMigration.migrate([%{id: id(mirror)}])

      assert {:ok, %{type: :group}} = Categories.get(id(mirror), skip_boundary_check: true)

      assert Enum.sort(acls_before) ==
               Enum.sort(
                 Bonfire.Boundaries.Controlleds.list_on_object(id(mirror))
                 |> Enum.map(& &1.acl_id)
               )
    end
  end
end
