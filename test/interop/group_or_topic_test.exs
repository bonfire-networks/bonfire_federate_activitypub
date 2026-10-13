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
      @friendica => read.("friendica", "forum_actor.json")
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
  end

  # what another Bonfire sends, as the test above has ours send it. A subgroup and a topic both name their `broader` group, so the parent is fetched and their `members` compared: the parent's (or none) is a topic, its own a subgroup
  describe "a Bonfire category from another instance is mirrored as" do
    for {label, extra, type} <- [
          {"a topic, when it names a broader group and declares that group's members",
           %{
             "broader" => "https://bonfire.local/pub/actors/parent",
             "members" => "https://bonfire.local/pub/collections/members/parent"
           }, :topic},
          {"a topic, when it names a broader group and declares no members",
           %{"broader" => "https://bonfire.local/pub/actors/parent"}, :topic},
          {"a group, when it names a broader group but has members of its own (a subgroup)",
           %{
             "broader" => "https://bonfire.local/pub/actors/parent",
             "members" => "https://bonfire.local/pub/collections/members/sub",
             "capabilities" => %{"acceptsJoins" => true}
           }, :group},
          {"a group, when nobody may post but it has members of its own (an archived group)",
           %{
             "postingRestrictedToMods" => true,
             "members" => "https://bonfire.local/pub/collections/members/archived",
             "capabilities" => %{"acceptsJoins" => true}
           }, :group}
        ] do
      test label, %{served: served} do
        bonfire_actor = fn id, extra ->
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

        parent_id = "https://bonfire.local/pub/actors/parent"

        parent =
          bonfire_actor.(parent_id, %{
            "members" => "https://bonfire.local/pub/collections/members/parent",
            "capabilities" => %{"acceptsJoins" => true}
          })

        id = "https://bonfire.local/pub/actors/#{System.unique_integer([:positive])}"
        actor = bonfire_actor.(id, unquote(Macro.escape(extra)))

        mock(fn
          %{method: :get, url: ^id} -> json(actor)
          %{method: :get, url: ^parent_id} -> json(parent)
          %{method: :get} -> %Tesla.Env{status: 404, body: ""}
          %{method: :post} -> %Tesla.Env{status: 202, body: ""}
        end)

        assert {:ok, %Bonfire.Classify.Category{} = mirror} =
                 Adapter.maybe_create_remote_actor(%{"id" => id})

        assert mirror.type == unquote(type)
      end
    end
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
