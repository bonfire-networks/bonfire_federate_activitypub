defmodule Bonfire.Federate.ActivityPub.FollowFanoutTest do
  @moduledoc """
  A `Follow` (and the `Undo` that retracts it) is for the account being followed, and nobody else.

  It used to go to every remote follower of the person following too: `basic_follow_data/2` addressed it to `as:Public`, and `APPublisher` fans out any public activity to all followers. So one Follow from an account with N remote followers cost 1 + N deliveries, which an account migration multiplies by the size of the following list (fedizen.net, 2026-10-09: ~108 re-follows × ~515 follower inboxes = 55k queued jobs, two days of outgoing lag). See team-docs/postmortems/2026-10-09-follow-fanout-outgoing-backlog.md

  Each follower here is alone on their host, so the publisher addresses their own `/inbox` rather than a shared one, which is the GoToSocial shape that made it so costly.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Social.Graph.Follows

  @follower_a "https://follower-a.local/users/alice"
  @follower_b "https://follower-b.local/users/bob"
  @followed "https://followed.local/users/carol"
  @remote_actors [@follower_a, @follower_b, @followed]

  setup do
    test_pid = self()

    mock(fn
      %{method: :post, url: url, body: body} ->
        send(test_pid, {:delivered, url, body})
        %Tesla.Env{status: 202, body: ""}

      %{method: :get, url: url} = env ->
        if url in @remote_actors do
          json(Simulate.actor_json(url, username_from(url)))
        else
          apply(ActivityPub.Test.HttpRequestMock, :request, [env])
        end
    end)

    Process.put(:federating, true)

    author = fake_user!("follow_fanout_author")
    remote_follower_of(author, @follower_a)
    remote_follower_of(author, @follower_b)
    {:ok, followed} = remote_user(@followed)

    # whatever setting up the followers queued (eg. Accepts) is not what these tests are about
    drain_and_flush()

    %{author: author, followed: followed}
  end

  defp username_from(actor_id), do: actor_id |> String.split("/") |> List.last()

  defp remote_user(ap_id) do
    {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)
    Bonfire.Federate.ActivityPub.AdapterUtils.return_pointable(actor)
  end

  defp remote_follower_of(author, ap_id) do
    {:ok, user} = remote_user(ap_id)
    {:ok, _} = Follows.follow(user, author, skip_boundary_check: true)
    user
  end

  defp drain_and_flush do
    Oban.drain_queue(queue: :federator_outgoing, with_recursion: true)
    flush_deliveries()
  end

  defp flush_deliveries do
    receive do
      {:delivered, _, _} -> flush_deliveries()
    after
      0 -> :ok
    end
  end

  # run every queued delivery, and report the hosts each activity type actually reached
  defp delivered_hosts_by_type do
    Oban.drain_queue(queue: :federator_outgoing, with_recursion: true)
    collect_deliveries(%{})
  end

  defp collect_deliveries(acc) do
    receive do
      {:delivered, url, body} ->
        type = Jason.decode!(body)["type"]
        acc |> Map.update(type, [URI.parse(url).host], &[URI.parse(url).host | &1]) |> collect_deliveries()
    after
      0 -> Map.new(acc, fn {type, hosts} -> {type, hosts |> Enum.uniq() |> Enum.sort()} end)
    end
  end

  defp collect_raw(acc) do
    receive do
      {:delivered, url, body} -> collect_raw([{URI.parse(url).host, Jason.decode!(body)} | acc])
    after
      0 -> acc
    end
  end

  defp delivered_payloads(type) do
    Oban.drain_queue(queue: :federator_outgoing, with_recursion: true)
    collect_payloads(type, [])
  end

  defp collect_payloads(type, acc) do
    receive do
      {:delivered, _url, body} ->
        payload = Jason.decode!(body)
        collect_payloads(type, if(payload["type"] == type, do: [payload | acc], else: acc))
    after
      0 -> acc
    end
  end

  test "the control: a public post does reach both remote followers", %{author: author} do
    {:ok, post} =
      Bonfire.Posts.publish(
        current_user: author,
        post_attrs: %{post_content: %{html_body: "a post for my followers"}},
        boundary: "public"
      )

    {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(post)

    assert %{"Create" => hosts} = delivered_hosts_by_type()

    assert "follower-a.local" in hosts and "follower-b.local" in hosts,
           "without this the tests below would pass for want of followers, not because Follows stay addressed"
  end

  test "a Follow is delivered to the followed account only", %{author: author, followed: followed} do
    {:ok, follow} = Follows.follow(author, followed)
    {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

    assert %{"Follow" => ["followed.local"]} = delivered_hosts_by_type(),
           "a Follow is for who is being followed; my followers' servers have no use for it"
  end

  test "a Follow is not addressed to the public", %{author: author, followed: followed} do
    {:ok, follow} = Follows.follow(author, followed)
    {:ok, _} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

    assert [payload | _] = delivered_payloads("Follow")

    refute ActivityPub.Utils.has_as_public?(List.wrap(payload["to"]) ++ List.wrap(payload["cc"])),
           "Mastodon and GoToSocial address a Follow to its object alone: #{inspect(Map.take(payload, ["to", "cc"]))}"
  end

  test "an unfollow (Undo of the Follow) is delivered to the followed account only", %{
    author: author,
    followed: followed
  } do
    {:ok, follow} = Follows.follow(author, followed)
    {:ok, follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)

    # the remote accepts, so this is a real unfollow: retracting a still-pending request goes through `Requests.unrequest/3`, which federates nothing at all
    {:ok, ap_author} = ActivityPub.Federator.Adapter.get_actor_by_id(author.id)
    {:ok, ap_followed} = ActivityPub.Actor.get_cached(ap_id: @followed)

    {:ok, accept} =
      ActivityPub.accept(%{
        actor: ap_followed,
        to: [ap_author.data],
        object: follow_activity.data,
        local: false
      })

    assert {:ok, _} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(accept)
    assert Follows.following?(author, followed)
    drain_and_flush()

    assert {:ok, _} = Follows.unfollow(author, followed)

    assert %{"Undo" => ["followed.local"]} = delivered_hosts_by_type()
  end

  # cancelling while the remote has not answered yet: without an Undo it keeps the request, and accepting it later would make me follow someone I chose not to
  test "cancelling a pending follow request tells the followed account, and only them", %{
    author: author,
    followed: followed
  } do
    {:ok, follow} = Follows.follow(author, followed)
    {:ok, follow_activity} = Bonfire.Federate.ActivityPub.Outgoing.push_now!(follow)
    drain_and_flush()

    assert Follows.requested?(author, followed)
    assert {:ok, _} = Follows.unfollow(author, followed)
    refute Follows.requested?(author, followed)

    Oban.drain_queue(queue: :federator_outgoing, with_recursion: true)
    undos = for {host, %{"type" => "Undo"} = payload} <- collect_raw([]), do: {host, payload}

    assert [{"followed.local", undo}] = undos,
           "one Undo, to the followed account only: #{inspect(Enum.map(undos, &elem(&1, 0)))}"

    assert undo["object"]["id"] == follow_activity.data["id"],
           "the Undo has to name the very Follow the remote is holding, or it has nothing to match it against"
  end
end
