defmodule Bonfire.Federate.ActivityPub.PeertubeAnnouncedVideoLinkedTest do
  @moduledoc """
  Regression for bonfire-app#1774: an `Announce`d (boosted) PeerTube `Video` must not be left as
  an orphaned `ap_object` (the inner Video object must be ingested and linked, `pointer_id` set) —
  not just turned into a Boost edge. Empirically this already works (handle_incoming fetches the
  announced video, which ingests it as Media and links it); this guards against regressing it.

  (The `Create{Video}` linking is covered by `media_test.exs`; skipped `View` activities are
  expected to have no pointer — see #1802.)
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  import Ecto.Query

  alias Bonfire.Federate.ActivityPub.Incoming
  alias ActivityPub.Federator.Transformer

  @actor "https://mocked.local/users/karen"
  @video_id "https://peertube.linuxrocks.local/videos/watch/954da380-e233-41d9-b0c4-c0a68dabfb08"

  setup_all do
    video =
      "../fixtures/peertube-video.json" |> Path.expand(__DIR__) |> File.read!() |> Jason.decode!()

    mock_global(fn
      %{method: :get, url: @actor} ->
        json(Simulate.actor_json(@actor))

      %{method: :get, url: @video_id} ->
        json(video)

      %{
        method: :get,
        url: "https://mocked.local/.well-known/webfinger?resource=https%3A%2F%2Fmocked.local"
      } ->
        %Tesla.Env{status: 404, body: ""}

      %{method: :get, url: "https://mocked.local/.well-known/nodeinfo"} ->
        %Tesla.Env{status: 404, body: ""}

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  test "an Announce'd PeerTube Video is ingested + linked (not an orphaned ap_object)" do
    announce = %{
      "type" => "Announce",
      "id" => "https://mocked.local/users/karen/announces/954da380",
      "actor" => @actor,
      "object" => @video_id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => []
    }

    {:ok, data} = Transformer.handle_incoming(announce)
    # boost edge creation may report "already boosted" (the fetch above can create it first) —
    # irrelevant here; we only care that the inner Video object is linked.
    Incoming.receive_activity(data)

    video_row =
      repo().one(
        from(o in ActivityPub.Object,
          where: fragment("?->>'id' = ?", o.data, ^@video_id),
          select: %{pointer_id: o.pointer_id, is_object: o.is_object}
        )
      )

    assert video_row, "the announced Video should be stored as an ap_object"
    assert video_row.is_object

    refute is_nil(video_row.pointer_id),
           "the announced Video's ap_object must be linked to a local record (#1774 orphan guard)"
  end
end
