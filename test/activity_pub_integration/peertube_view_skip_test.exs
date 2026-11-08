defmodule Bonfire.Federate.ActivityPub.PeertubeViewSkipTest do
  @moduledoc """
  bonfire-app#1802: an incoming PeerTube `View` activity (a view-count ping Bonfire doesn't model)
  fell through to the fallback handler and crashed with a `DBConnection.EncodeError` (a ~32-bit
  value overflowing an int4 column), which the Oban worker then retried 3×. Such activities must
  now be skipped cleanly (`{:ok, :skip}`) before any object fetch/store.
  """
  use Bonfire.Federate.ActivityPub.DataCase
  alias Bonfire.Federate.ActivityPub.Incoming

  @peertube_actor "https://fedi.video/accounts/peertube"
  @video "https://fedi.video/videos/watch/cc1c9578-2fdf-4391-9e61-f0065f6bbfec"
  @view_id "https://fedi.video/accounts/peertube/views/videos/39916/cc1c9578-2fdf-4391-9e61-f0065f6bbfec"

  test "an incoming PeerTube `View` activity is skipped cleanly (not fetched/stored, no DB error)" do
    # the exact shape from the Sentry report (op: incoming_ap_doc)
    view_activity = %{
      "type" => "View",
      "id" => @view_id,
      "actor" => @peertube_actor,
      "object" => @video,
      "to" => [],
      "cc" => []
    }

    assert {:ok, :skip} = Incoming.receive_activity(view_activity)
  end

  # the same ping arrives again and again; storing it first made the second delivery hit the unique index, and the worker retried that
  test "the library skips a `View` before storing it, so a repeated one is not an error" do
    view_activity = %{
      "type" => "View",
      "id" => @view_id,
      "actor" => @peertube_actor,
      "object" => @video,
      "to" => [],
      "cc" => []
    }

    opts = [from_inbox: true]

    first = ActivityPub.Federator.Transformer.handle_incoming(view_activity, opts)
    second = ActivityPub.Federator.Transformer.handle_incoming(view_activity, opts)

    refute match?({:error, _}, first), "first delivery: #{inspect(first)}"
    refute match?({:error, _}, second), "repeated delivery: #{inspect(second)}"

    assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: @view_id),
           "no row is stored for a type we skip"
  end
end
