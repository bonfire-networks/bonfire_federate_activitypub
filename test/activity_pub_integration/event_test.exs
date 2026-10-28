defmodule Bonfire.Federate.ActivityPub.EventTest do
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  require Ecto.Query

  alias Bonfire.Posts

  setup_all do
    mock_global(fn
      %{method: :get, url: "https://mocked.local/users/karen"} ->
        json(Simulate.actor_json("https://mocked.local/users/karen"))

      %{
        method: :get,
        url: "https://mocked.local/.well-known/webfinger?resource=https%3A%2F%2Fmocked.local"
      } ->
        %Tesla.Env{status: 404, body: ""}

      %{
        method: :get,
        url: "https://mocked.local/.well-known/nodeinfo"
      } ->
        %Tesla.Env{status: 404, body: ""}

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  describe "" do
    test "event is recorded as APActivity" do
      type = "Event"

      data =
        "../fixtures/mobilizon.org-event.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()

      # |> Map.put("type", type)

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      # NOTE: temp until an extension implements events
      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert activity.json["type"] == type
      assert is_binary(activity.json["content"])

      assert {:ok, _} = Bonfire.Social.Objects.read(activity.id)

      feed = Bonfire.Social.FeedLoader.feed(:explore)
      assert Bonfire.Social.FeedLoader.feed_contains?(feed, activity)

      feed = Bonfire.Social.FeedLoader.feed(:explore, %{object_types: ["Event"]}, [])
      assert Bonfire.Social.FeedLoader.feed_contains?(feed, activity)
    end

    test "non-public event is recorded as private APActivity" do
      recipient = fake_user!()
      recipient_actor = ActivityPub.Actor.get_cached!(pointer: recipient.id)

      type = "Event"

      data =
        "../fixtures/mobilizon.org-event.json"
        |> Path.expand(__DIR__)
        |> File.read!()
        |> Jason.decode!()
        # |> Map.put("type", type)
        |> Map.put("to", recipient_actor)

      {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)
      # |> debug("handled")

      assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)

      assert activity.__struct__ == Bonfire.Data.Social.APActivity
      assert activity.json["type"] == type
      assert is_binary(activity.json["content"])

      assert {:error, _} = Bonfire.Social.Objects.read(activity.id)
      assert {:ok, _} = Bonfire.Social.Objects.read(activity.id, current_user: recipient)
    end
  end

  # The Update handling is in the generic APActivity path, so it is run for an Event and for a made-up type that no module claims. When Event gets its own module, only the made-up type still goes through this path.
  describe "an Update of an object stored as an APActivity, received server to server" do
    @actor "https://mocked.local/users/karen"
    @public "https://www.w3.org/ns/activitystreams#Public"

    defp typed(type, id, name, tags \\ []) do
      %{
        "type" => type,
        "id" => id,
        "attributedTo" => @actor,
        "name" => name,
        "content" => "an event",
        "startTime" => "2026-11-01T18:00:00Z",
        "to" => [@public],
        "tag" => tags,
        "published" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    end

    defp hashtag(name), do: %{"type" => "Hashtag", "name" => "##{name}"}

    # the names of the hashtags (tags that are not characters) of the one record stored for this object id
    defp hashtag_names(id) do
      [record] = records_of(id)

      record
      |> Bonfire.Common.Repo.maybe_preload(tags: [:named, :character])
      |> Map.get(:tags)
      |> Enum.reject(& &1.character)
      |> Enum.map(& &1.named.name)
      |> Enum.sort()
    end

    defp records_of(id) do
      Bonfire.Common.Repo.all(
        Ecto.Query.from(a in Bonfire.Data.Social.APActivity,
          where: fragment("?->>'id' = ?", a.json, ^id)
        )
      )
    end

    defp receive_incoming(type, object) do
      result =
        ActivityPub.Federator.Transformer.handle_incoming(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "type" => type,
          "id" => "#{object["id"]}/#{String.downcase(type)}/#{Needle.UID.generate()}",
          "actor" => @actor,
          "to" => [@public],
          "object" => object
        })

      # an Update is already passed to Bonfire by `handle_incoming` (through `ActivityPub.update`), so only a Create needs the explicit call, as the inbox worker does
      case {type, result} do
        {"Create", {:ok, data}} -> Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
        _ -> result
      end
    end

    for type <- ["Event", "Workshop"] do
      test "updates the #{type} it is about, instead of recording a second one" do
        type = unquote(type)
        id = "#{@actor}/objects/#{Needle.UID.generate()}"

        assert {:ok, first} = receive_incoming("Create", typed(type, id, "the first name"))
        assert first.__struct__ == Bonfire.Data.Social.APActivity
        assert length(records_of(id)) == 1, "one record after the Create"

        assert {:ok, _} = receive_incoming("Update", typed(type, id, "the updated name"))

        assert length(records_of(id)) == 1,
               "one record after the Update, got #{length(records_of(id))}"

        pointer_id = ActivityPub.Object.get_cached!(ap_id: id).pointer_id

        assert pointer_id == first.id,
               "the AP object still points at the first record, not at a new one"

        assert Bonfire.Common.Repo.get(Bonfire.Data.Social.APActivity, first.id).json["name"] ==
                 "the updated name"
      end
    end

    test "re-casts the hashtags on an Update, keeping only the new ones" do
      id = "#{@actor}/objects/#{Needle.UID.generate()}"

      assert {:ok, _} =
               receive_incoming("Create", typed("Workshop", id, "a workshop", [hashtag("salad")]))

      assert hashtag_names(id) == ["salad"], "tagged as it arrived"

      assert {:ok, _} =
               receive_incoming("Update", typed("Workshop", id, "a workshop", [hashtag("soup")]))

      assert hashtag_names(id) == ["soup"]
    end
  end
end
