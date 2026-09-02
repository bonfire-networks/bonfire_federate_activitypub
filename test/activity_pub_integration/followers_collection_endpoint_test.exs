defmodule Bonfire.Federate.ActivityPub.FollowersCollectionEndpointTest do
  @moduledoc """
  T4 (team-docs/plans/ap-followers-collections-tdd.md): the `followers` collection through
  Bonfire's router with a mixed local + remote follower fixture, plus the per-request DB query
  bound — the number that was ~150+ per request during the 2026-08-30 storm.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock

  alias Bonfire.Common.URIs
  alias Bonfire.Social.Graph.Follows

  @page_size 10
  @remote_actors for i <- 1..3, do: "https://mocked.local/users/epfollower#{i}"

  setup_all do
    mock_global(fn
      %{method: :get, url: url} = env ->
        if url in @remote_actors do
          json(mocked_follower_json(url))
        else
          case url do
            "https://mocked.local/.well-known/" <> _ -> %Tesla.Env{status: 404, body: ""}
            _ -> apply(ActivityPub.Test.HttpRequestMock, :request, [env])
          end
        end
    end)
  end

  # `Simulate.actor_json/1` only knows a few fixed actor ids (and DataHelpers.remote_actor_json/1 is a bare stub); derive full actor JSON from the karen fixture
  defp mocked_follower_json(actor_id) do
    %{"host" => host, "path" => path} =
      Regex.named_captures(~r{^https://(?<host>[^/]+)/users/(?<path>[^/]+)$}, actor_id)

    Simulate.actor_json("https://mocked.local/users/karen")
    |> Map.merge(%{
      "id" => actor_id,
      "preferredUsername" => path,
      "name" => "test user #{path}",
      "url" => "https://#{host}/@#{path}",
      "followers" => actor_id <> "/followers",
      "following" => actor_id <> "/following",
      "inbox" => actor_id <> "/inbox",
      "outbox" => actor_id <> "/outbox"
    })
    |> put_in(["endpoints", "sharedInbox"], "https://#{host}/inbox")
    |> put_in(["publicKey", "id"], actor_id <> "#main-key")
    |> put_in(["publicKey", "owner"], actor_id)
  end

  setup do
    Process.put(:federating, true)

    user = fake_user!("endpoint_owner")
    {:ok, actor} = ActivityPub.Federator.Adapter.get_actor_by_id(user.id)

    local_followers =
      for i <- 1..12 do
        follower = fake_user!("ep_local_follower_#{i}")
        {:ok, _} = Follows.follow(follower, user)
        follower
      end

    remote_followers =
      for ap_id <- @remote_actors do
        {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)

        {:ok, follow_activity} =
          ActivityPub.follow(%{actor: remote_actor, object: actor, local: false})

        {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)
        remote_actor
      end

    expected_uris =
      MapSet.new(
        Enum.map(local_followers, &URIs.canonical_url/1) ++ Enum.map(remote_followers, & &1.ap_id)
      )

    {:ok, user: user, actor: actor, expected_uris: expected_uris}
  end

  defp followers_url(actor, page \\ nil) do
    base = "#{ActivityPub.Utils.ap_base_url()}/actors/#{actor.username}/followers"
    if page, do: "#{base}?page=#{page}", else: base
  end

  defp get_collection(url) do
    json_conn()
    |> get(url)
    |> json_response(200)
  end

  defp with_query_count(fun) do
    handler_id = {__MODULE__, make_ref()}
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    query_event = EctoSparkles.Log.query_event(Bonfire.Common.Repo)

    :telemetry.attach(
      handler_id,
      query_event,
      fn _event, _measure, _meta, _cfg -> Agent.update(counter, &(&1 + 1)) end,
      nil
    )

    try do
      result = fun.()
      {result, Agent.get(counter, & &1)}
    after
      :telemetry.detach(handler_id)
      Agent.stop(counter)
    end
  end

  describe "T4-a: envelope with mixed local + remote followers" do
    test "top level + pages", %{actor: actor, expected_uris: expected_uris} do
      top = get_collection(followers_url(actor))
      assert top["type"] == "Collection"
      assert top["totalItems"] == 15
      assert length(top["first"]["orderedItems"]) == @page_size
      assert top["first"]["next"] == "#{actor.ap_id}/followers?page=2"

      page2 = get_collection(followers_url(actor, 2))
      assert length(page2["orderedItems"]) == 5
      assert page2["totalItems"] == 15
      refute Map.has_key?(page2, "next")

      page3 = get_collection(followers_url(actor, 3))
      assert page3["orderedItems"] == []

      served = MapSet.new(top["first"]["orderedItems"] ++ page2["orderedItems"])
      assert served == expected_uris
    end

    test "items are bare URIs, never embedded actor objects", %{actor: actor} do
      page1 = get_collection(followers_url(actor, 1))
      assert Enum.all?(page1["orderedItems"], &is_binary/1)
    end
  end

  describe "T4-b: a page request is a bounded number of DB queries" do
    test "one followers page costs <= 18 queries", %{actor: actor} do
      # warm anything request-independent (served actor lookup etc.) with a first request
      _ = get_collection(followers_url(actor, 1))

      {_page, count} = with_query_count(fn -> get_collection(followers_url(actor, 1)) end)

      # measured constant after the fix: 16 (actor lookup + count + page ids + batched URI
      # resolution + request plumbing). Was 43 with only 15 followers before, growing O(followers);
      # a per-actor preload regression puts this back over 40 even at fixture scale.
      assert count <= 18,
             "expected <= 18 DB queries for one followers page, got #{count} (was O(followers) before)"
    end
  end
end
