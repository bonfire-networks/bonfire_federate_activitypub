defmodule Bonfire.Federate.ActivityPub.RelayedUnheldPostTrustTest do
  @moduledoc """
  A post we do not hold, relayed inside an `Announce{Create}` (FEP-1b12), is taken from the relayer unfetched only when the relayer is a Group that someone here follows (an accepted Follow by one of our actors) and the post's own `audience` names it. For anyone else the `Create` is kept with the post's id only: nothing is stored under that id from the relay, and the post is fetched from its origin only if something needs it, and stored only if the origin serves it.

  The origin of the post is the member's own server, which here serves nothing (404) unless a test says otherwise.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias ActivityPub.Federator.Transformer
  alias Bonfire.Federate.ActivityPub.Adapter

  @public "https://www.w3.org/ns/activitystreams#Public"
  @member "https://member.local/users/mia"
  @group "https://threads.local/c/technology"
  @other_group "https://other.local/c/music"
  @person "https://person.local/users/pat"

  setup do
    actors = %{
      @member => Simulate.actor_json(@member, "mia"),
      @group => Simulate.actor_json(@group, "technology") |> Map.put("type", "Group"),
      @other_group => Simulate.actor_json(@other_group, "music") |> Map.put("type", "Group"),
      @person => Simulate.actor_json(@person, "pat")
    }

    {:ok, served} = start_supervised({Agent, fn -> %{} end})

    mock(fn
      %{method: :get, url: url} ->
        case actors[url] || Agent.get(served, &Map.get(&1, url)) do
          nil -> %Tesla.Env{status: 404, body: ""}
          doc -> json(doc)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    for id <- [@member, @group, @other_group, @person],
        do: {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: id)

    %{served: served}
  end

  defp post_id, do: "https://member.local/post/#{System.unique_integer([:positive])}"

  defp page(id, audience) do
    %{
      "type" => "Page",
      "id" => id,
      "attributedTo" => @member,
      "to" => [@public],
      "name" => "relayed #{System.unique_integer([:positive])}",
      "content" => "what the relay says",
      "published" => "2026-08-25T19:05:56Z",
      "audience" => audience
    }
  end

  # `relayer`'s `Announce` of a `Create` by the member of `object`
  defp announce(relayer, object) do
    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{relayer}/announce/#{System.unique_integer([:positive])}",
      "type" => "Announce",
      "actor" => relayer,
      "to" => [@public],
      "object" => %{
        "id" => "https://member.local/activities/create/#{System.unique_integer([:positive])}",
        "type" => "Create",
        "actor" => @member,
        "to" => [@public],
        "audience" => object["audience"],
        "object" => object
      }
    }
  end

  # one of our users follows `group_id`, and the group has accepted
  defp follow_accepted!(group_id) do
    follower = fake_user!()
    {:ok, follower_actor} = ActivityPub.Actor.get_cached(pointer: follower)
    {:ok, group} = Adapter.maybe_create_remote_actor(%{"id" => group_id})

    assert {:ok, request} = Bonfire.Social.Graph.Follows.follow(follower, group)
    follow_activity = Bonfire.Federate.ActivityPub.Outgoing.ap_activity!(request)

    accept = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{group_id}/accept/#{System.unique_integer([:positive])}",
      "type" => "Accept",
      "actor" => group_id,
      "to" => [follower_actor.ap_id],
      "object" => %{
        "id" => follow_activity.data["id"],
        "type" => "Follow",
        "actor" => follower_actor.ap_id,
        "object" => group_id,
        "state" => "pending"
      }
    }

    assert {:ok, _} = Transformer.handle_incoming(accept)
    assert ActivityPub.Object.accepted_local_follow?(group_id)
  end

  defp held?(id), do: match?({:ok, _}, ActivityPub.Object.get_cached(ap_id: id))

  test "control: a Group that one of our users follows, named in the post's audience, is taken unfetched" do
    follow_accepted!(@group)
    id = post_id()

    Transformer.handle_incoming(announce(@group, page(id, @group)))

    assert {:ok, %{data: %{"content" => "what the relay says"}}} =
             ActivityPub.Object.get_cached(ap_id: id)
  end

  test "an ordinary actor relaying a post we do not hold stores nothing under the post's id" do
    id = post_id()

    Transformer.handle_incoming(announce(@person, page(id, @person)))

    refute held?(id), "a post relayed by a non-Group was stored under its id"
  end

  test "a Group that nobody here follows stores nothing under the post's id" do
    id = post_id()

    Transformer.handle_incoming(announce(@other_group, page(id, @other_group)))

    refute held?(id), "a post relayed by a Group nobody follows was stored under its id"
  end

  test "a followed Group that the post's audience does not name stores nothing under the post's id" do
    follow_accepted!(@group)
    id = post_id()

    Transformer.handle_incoming(announce(@group, page(id, @other_group)))

    refute held?(id), "a post relayed by a group it does not name was stored under its id"
  end

  test "the post of an untrusted relay is stored from its origin when the origin serves it", %{
    served: served
  } do
    id = post_id()

    Agent.update(
      served,
      &Map.put(
        &1,
        id,
        page(id, @person)
        |> Map.put("@context", "https://www.w3.org/ns/activitystreams")
        |> Map.put("content", "what the origin says")
      )
    )

    Transformer.handle_incoming(announce(@person, page(id, @person)))

    assert {:ok, %{data: %{"content" => "what the origin says"}}} =
             ActivityPub.Object.get_cached(ap_id: id)
  end
end
