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
end
