defmodule Bonfire.Federate.ActivityPub.CategoryTagsTest do
  @moduledoc """
  The tags of an `Event` that arrives from a remote actor (S2S). See `plans/events-categories.md`.

  Nothing models an `Event`, so it is stored as an `APActivity` with the raw AS2 json, and the items of its `tag` have to become real tags there.
  """
  # `@moduletag :federation` comes with this case
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  import Bonfire.Classify.Simulate

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

  # the Mobilizon event of `event_test.exs`, with the given `tag`, ingested as a remote one, as an `APActivity` with its tags
  defp receive_remote_event(tags) do
    data =
      "../fixtures/mobilizon.org-event.json"
      |> Path.expand(__DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("tag", tags)

    {:ok, data} = ActivityPub.Federator.Transformer.handle_incoming(data)

    assert {:ok, activity} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
    assert %Bonfire.Data.Social.APActivity{} = activity

    repo().maybe_preload(activity, tags: [:named, :character])
  end

  describe "an Event from a remote actor" do
    # a baseline, expected GREEN before any change: it shows the remote path tags at all
    test "has its Hashtag tag tagged" do
      activity = receive_remote_event([%{"type" => "Hashtag", "name" => "#jazz"}])

      hashtag_names =
        activity.tags
        |> Enum.filter(&is_nil(e(&1, :character, nil)))
        |> Enum.map(&e(&1, :named, :name, nil))

      assert "jazz" in hashtag_names
    end

    # a guard, expected GREEN before and after the C2S steps: they apply to local creators only, and this is replaced by the S2S steps
    test "is not tagged with the local category its Category tag names" do
      creator = fake_user!()
      topic = fake_category!(creator, nil, %{type: :topic, name: "Jazz"})
      iri = Bonfire.Me.Characters.character_url(topic)

      activity =
        receive_remote_event([
          %{"type" => "Category", "id" => iri, "name" => "Jazz"},
          # the precondition: this event's tags are processed, so the Category item was passed over rather than the tags never read
          %{"type" => "Hashtag", "name" => "#jazz"}
        ])

      tag_ids = Enum.map(activity.tags, & &1.id)

      assert length(tag_ids) > 0, "the event's tags were not processed at all"
      refute topic.id in tag_ids
    end
  end
end
