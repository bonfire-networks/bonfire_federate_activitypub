defmodule Bonfire.Federate.ActivityPub.FollowersCollectionPagingTest do
  @moduledoc """
  T3 (team-docs/plans/ap-followers-collections-tdd.md): the Bonfire adapter side of the
  `followers` / `following` collections.

  - T3-a: paging + counting happen in SQL (`Follows.page_follower_ids/2`, `count_followers/2`,
    and the followed mirrors) — O(page) cost regardless of follower count, stable order
  - T3-b: `Adapter.get_actor_ap_ids_by_ids/1` resolves pointer ids straight to canonical URIs
    (local via `URIs.canonical_url`, remote via `peered.canonical_uri`), in input order, no
    `%Actor{}` formatting
  - T3-c: resolving a page of ids costs a bounded number of DB queries (guards the preload)
  - T3-d: the paged query keeps the visibility semantics of the unpaged one
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Common.URIs
  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Social.Graph.Follows

  @page_size 10
  @remote_actors for i <- 1..3, do: "https://mocked.local/users/follower#{i}"

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

  # one local user with 12 local followers + 3 remote followers (15 total), who follows 12 locals
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

    user = fake_user!("collection_owner")
    {:ok, actor} = ActivityPub.Federator.Adapter.get_actor_by_id(user.id)

    local_followers =
      for i <- 1..12 do
        follower = fake_user!("local_follower_#{i}")
        {:ok, _} = Follows.follow(follower, user)
        follower
      end

    remote_followers =
      for ap_id <- @remote_actors do
        {:ok, remote_actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)

        {:ok, follow_activity} =
          ActivityPub.follow(%{actor: remote_actor, object: actor, local: false})

        {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(follow_activity)

        # re-load AFTER the receive created the local user record: the struct captured at fetch
        # time is a snapshot whose `pointer_id` may still be nil
        {:ok, remote_actor} = ActivityPub.Actor.get_cached(ap_id: ap_id)
        false = is_nil(remote_actor.pointer_id)
        remote_actor
      end

    followed =
      for i <- 1..12 do
        other = fake_user!("followed_#{i}")
        {:ok, _} = Follows.follow(user, other)
        other
      end

    {:ok,
     user: user,
     actor: actor,
     local_followers: local_followers,
     remote_followers: remote_followers,
     followed: followed}
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

  describe "T3-a: Follows pages and counts in SQL" do
    test "page_follower_ids/2 pages the follower pointer ids", %{user: user} do
      page1 = Follows.page_follower_ids(user, page: 1, page_size: @page_size)
      page2 = Follows.page_follower_ids(user, page: 2, page_size: @page_size)
      page3 = Follows.page_follower_ids(user, page: 3, page_size: @page_size)

      assert length(page1) == @page_size
      assert length(page2) == 5
      assert page3 == []
      assert MapSet.disjoint?(MapSet.new(page1), MapSet.new(page2))
    end

    test "count_followers/1 counts without loading the list", %{user: user} do
      assert Follows.count_followers(user) == 15
    end

    test "pages together cover exactly the unpaged follower set", %{user: user} do
      all = Follows.all_subjects_by_object(user, preload: :subject_id_only) |> List.flatten()

      paged =
        Follows.page_follower_ids(user, page: 1, page_size: @page_size) ++
          Follows.page_follower_ids(user, page: 2, page_size: @page_size)

      assert MapSet.new(paged) == MapSet.new(all)
    end

    test "page order is stable across calls", %{user: user} do
      assert Follows.page_follower_ids(user, page: 1, page_size: @page_size) ==
               Follows.page_follower_ids(user, page: 1, page_size: @page_size)
    end

    test "page_followed_ids/2 and count_followed/1 mirror the followed side", %{
      user: user,
      followed: followed
    } do
      expected = followed |> Enum.map(& &1.id) |> MapSet.new()

      page1 = Follows.page_followed_ids(user, page: 1, page_size: @page_size)
      page2 = Follows.page_followed_ids(user, page: 2, page_size: @page_size)

      assert length(page1) == @page_size
      assert length(page2) == 2
      assert MapSet.new(page1 ++ page2) == expected
      assert Follows.count_followed(user) == 12
    end

    test "paging a page costs a constant number of queries", %{user: user} do
      {_ids, count} =
        with_query_count(fn ->
          Follows.page_follower_ids(user, page: 1, page_size: @page_size)
        end)

      assert count <= 2, "expected <= 2 queries for one page of ids, got #{count}"
    end
  end

  describe "T3-b: Adapter.get_actor_ap_ids_by_ids/1 resolves ids straight to URIs" do
    test "local followers resolve to their canonical url, remote to peered canonical_uri", %{
      local_followers: local_followers,
      remote_followers: remote_followers
    } do
      locals = Enum.take(local_followers, 3)
      ids = Enum.map(locals, & &1.id) ++ Enum.map(remote_followers, & &1.pointer_id)

      expected =
        Enum.map(locals, &URIs.canonical_url/1) ++ Enum.map(remote_followers, & &1.ap_id)

      assert Adapter.get_actor_ap_ids_by_ids(ids) == expected
    end

    test "input order is preserved", %{local_followers: local_followers} do
      locals = local_followers |> Enum.take(4) |> Enum.reverse()
      ids = Enum.map(locals, & &1.id)

      assert Adapter.get_actor_ap_ids_by_ids(ids) == Enum.map(locals, &URIs.canonical_url/1)
    end

    test "unknown ids are dropped, not returned as nil", %{local_followers: [one | _]} do
      assert Adapter.get_actor_ap_ids_by_ids([one.id, Needle.UID.generate()]) ==
               [URIs.canonical_url(one)]
    end

    test "empty in, empty out" do
      assert Adapter.get_actor_ap_ids_by_ids([]) == []
    end
  end

  describe "T3-c: resolving a page is a bounded number of queries (no per-actor preloads)" do
    test "10 mixed ids resolve in <= 6 queries", %{
      local_followers: local_followers,
      remote_followers: remote_followers
    } do
      ids =
        Enum.map(Enum.take(local_followers, 7), & &1.id) ++
          Enum.map(remote_followers, & &1.pointer_id)

      {uris, count} = with_query_count(fn -> Adapter.get_actor_ap_ids_by_ids(ids) end)

      assert length(uris) == 10

      # constant budget: 2 for Needles.list! (pointer + concrete rows) + 3 batched preloads
      # (shared_user, character, peered), +1 headroom. A per-actor preload regression would
      # cost ~5 × ids and blow well past this.
      assert count <= 6, "expected <= 6 queries to resolve 10 ids to URIs, got #{count}"
    end
  end

  describe "T3-d: the adapter's paged callbacks keep the unpaged visibility semantics" do
    test "get_follower_local_ids/3 with page opts is a page of get_follower_local_ids/2", %{
      actor: actor
    } do
      all = Adapter.get_follower_local_ids(actor, nil)
      assert length(all) == 15

      page1 = Adapter.get_follower_local_ids(actor, nil, page: 1, page_size: @page_size)
      page2 = Adapter.get_follower_local_ids(actor, nil, page: 2, page_size: @page_size)

      assert length(page1) == @page_size
      assert MapSet.new(page1 ++ page2) == MapSet.new(all)
      assert Adapter.count_followers(actor, nil) == 15
    end

    test "get_following_local_ids/3 with page opts is a page of get_following_local_ids/2", %{
      actor: actor
    } do
      all = Adapter.get_following_local_ids(actor, nil)
      assert length(all) == 12

      page1 = Adapter.get_following_local_ids(actor, nil, page: 1, page_size: @page_size)
      page2 = Adapter.get_following_local_ids(actor, nil, page: 2, page_size: @page_size)

      assert MapSet.new(page1 ++ page2) == MapSet.new(all)
      assert Adapter.count_following(actor, nil) == 12
    end
  end
end
