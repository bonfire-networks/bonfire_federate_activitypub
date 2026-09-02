defmodule Bonfire.Federate.ActivityPub.HubzillaInteropTest do
  @moduledoc """
  Interop pass for FEP-171b conversation containers, as Hubzilla sends them.

  Fixtures are REAL captures from a public Hubzilla 11.4 forum's outbox (2026-08-30), with instance hostnames rewritten to `.local` stand-ins; provenance is in the group federation plan.

  **This family relays with `Add`, not `Announce`.** All 9 items in the captured outbox were either the forum's own `Create{Note}` or `Add{Create{Note}}`, and not one was an `Announce`, so a consumer that only understands FEP-1b12 sees nothing at all from a Hubzilla forum.

  | | threadiverse (1b12) | Hubzilla (171b) |
  |---|---|---|
  | relay activity | `Announce` | `Add` |
  | belongs-to marker | `audience` | `context` (+ `contextHistory`) |
  | container | the group actor | a `/conversation/<uuid>` collection |
  | moderators | `attributedTo` collection | absent |

  The `Add` wraps a complete `Create` activity, exactly as 1b12's `Announce` does, which is why the incoming clause is a generalisation of the one we already have rather than a separate path. FEP-400e (Smithereen walls, Discourse topics) is the other `Add` shape and differs: there the object is an OBJECT, not an activity.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @fixtures Path.join([__DIR__, "..", "fixtures", "hubzilla"])
  @forum "https://hubzilla.local/channel/berlin"

  setup do
    by_member = fixture("add_create_note_by_member.json")
    note = by_member["object"]["object"]

    by_url = %{
      @forum => fixture("forum_actor.json"),
      note["id"] => note,
      note["attributedTo"] => author_actor(note["attributedTo"])
    }

    mock(fn %{method: :get, url: url} ->
      case by_url[url] do
        nil -> %Tesla.Env{status: 404, body: ""}
        body -> json(body)
      end
    end)

    {:ok, add: by_member, note: note}
  end

  test "the forum actor becomes a local group" do
    assert {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => @forum})

    assert %Bonfire.Classify.Category{type: :group} = group,
           "a Hubzilla forum declares `type: Group`, so it needs no rewrite allowlist"
  end

  # Hubzilla omits `attributedTo` entirely, where every threadiverse implementor points it at a
  # moderators collection. Recorded as a test because it decides whether we can validate incoming
  # moderation from this family at all: with no moderators collection, the only check available is
  # same-origin as the forum.
  test "the forum actor declares no moderators collection" do
    actor = fixture("forum_actor.json")

    refute actor["attributedTo"],
           "if this ever gains an `attributedTo`, incoming moderation from Hubzilla can be validated the 1b12 way"

    assert actor["manuallyApprovesFollowers"] == false,
           "an open forum, which is what maps to `membership: open`"
  end

  test "an Add of a member's Create ingests the post, still attributed to the member", %{
    add: add,
    note: note
  } do
    receive_add(add)

    assert {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: note["id"]),
           "the added object should be stored as an ap_object"

    post =
      Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true)
      |> repo().maybe_preload([:post_content, created: [creator: [character: [:peered]]]])

    assert URIs.canonical_url(e(post, :created, :creator, nil)) == note["attributedTo"],
           "attribution belongs to the member who wrote it, not the forum that added it"
  end

  test "the added post lands in the forum's feed", %{add: add, note: note} do
    receive_add(add)

    group = AdapterUtils.get_character_by_ap_id!(@forum)
    {:ok, %{pointer_id: pointer_id}} = ActivityPub.Object.get_cached(ap_id: note["id"])
    post = Bonfire.Common.Needles.get!(pointer_id, skip_boundary_check: true)

    assert Bonfire.Social.FeedLoader.feed_contains?(:user_activities, post,
             by: group,
             current_user: group
           ),
           "an added post should land in the forum's feed, as an announced one does for 1b12"
  end

  # Replying into a 171b conversation means quoting the container back, so the id has to survive
  # ingest. `transformer.ex` already reads `context || conversation || inReplyTo`, so this asserts
  # the property we depend on rather than new behaviour.
  test "the conversation container id survives ingest", %{add: add, note: note} do
    receive_add(add)

    assert {:ok, object} = ActivityPub.Object.get_cached(ap_id: note["id"])

    assert object.data["context"] == note["context"],
           "the `/conversation/<uuid>` id is what a reply must carry back, so it must not be dropped"
  end

  # `Add` is a general verb: "put this object in that collection". Only a container owner adding to
  # its OWN container is the 1b12-equivalent relay, so these two must not be mistaken for one.
  describe "what is NOT a container relay" do
    # It may well succeed, handled as an ordinary collection Add. What it must not do is ingest and
    # relay the wrapped activity as though a container had distributed it.
    test "an Add with no context does not relay the wrapped activity", %{add: add, note: note} do
      add |> Map.drop(["context"]) |> receive_add()

      assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: note["id"]),
             "without a container named in `context` there is nothing to relay into"
    end

    test "an Add naming a container on another host is refused", %{add: add, note: note} do
      add
      |> Map.put("context", "https://elsewhere.local/conversation/1")
      |> receive_add()

      assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: note["id"]),
             "adding someone else's activity to a container you do not own must not become a boost by you"
    end
  end

  defp receive_add(add) do
    case ActivityPub.Federator.Transformer.handle_incoming(add) do
      {:ok, activity} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
      {:error, _} -> :ok
    end
  end

  # `Simulate.actor_json/1` only matches a few hardcoded URLs, so start from one of those and swap
  # in the member's identity.
  defp author_actor(ap_id) do
    Bonfire.Federate.ActivityPub.Simulate.actor_json("https://mocked.local/users/karen")
    |> Map.merge(%{
      "id" => ap_id,
      "type" => "Person",
      "preferredUsername" => ap_id |> String.split("/") |> List.last(),
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox"
    })
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end

  defp fixture(name) do
    @fixtures |> Path.join(name) |> File.read!() |> Jason.decode!()
  end
end
