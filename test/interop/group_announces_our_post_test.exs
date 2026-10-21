defmodule Bonfire.Federate.ActivityPub.GroupAnnouncesOurPostTest do
  @moduledoc """
  A group hosted elsewhere announcing a post or reply of OURS back to us, which is how a community says it accepted what we published into it.

  Found by the live Lemmy run of 20 October: Lemmy answered our reply with `Announce{Create{Note}}`, and ingesting it crashed the shared inbox with an `Ecto.ConstraintError` on `bonfire_data_social_feed_publish_pkey`, so Lemmy saw a 500 and retried. The announce here is built the way Lemmy wraps it (`actor` the community, `to` Public, `cc` its followers, `object` our whole `Create`), around the `Create` we really send, so the ids are ours and nothing is hand-written.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock
  import Bonfire.Federate.ActivityPub.Test.ThreadiverseFixtures, only: [served_for: 1]

  alias ActivityPub.Federator.Transformer
  alias Bonfire.Federate.ActivityPub.Incoming
  alias Bonfire.Federate.ActivityPub.Outgoing

  @community %{
    name: "Lemmy",
    dir: "lemmy",
    id: "https://lemmy.local/c/technology",
    actor: "community_actor.json",
    announces: []
  }

  setup do
    served = Map.new(served_for([@community]))

    mock(fn
      %{method: :get, url: url} ->
        case served[url] do
          nil -> %Tesla.Env{status: 404, body: ""}
          body -> json(body)
        end

      %{method: :post} ->
        %Tesla.Env{status: 202, body: ""}
    end)

    assert {:ok, group} =
             Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(%{
               "id" => @community.id
             })

    user = fake_user!()
    assert {:ok, _} = Bonfire.Classify.Categories.join_and_follow_group(user, group)

    %{user: user, group: group}
  end

  defp publish_in(user, group, attrs) do
    assert {:ok, post} =
             Bonfire.Posts.publish(
               current_user: user,
               post_attrs: attrs,
               boundary: "public",
               publish_in: uid(group)
             )

    post
  end

  # as Lemmy sends it
  defp announce_of(post) do
    %{
      "@context" => [
        "https://www.w3.org/ns/activitystreams",
        "https://join-lemmy.org/context.json"
      ],
      "type" => "Announce",
      "id" => "#{@community.id}/announce/#{System.unique_integer([:positive])}",
      "actor" => @community.id,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "cc" => ["#{@community.id}/followers"],
      "object" => Outgoing.ap_activity!(post).data
    }
  end

  defp receive_announce(announce) do
    {:ok, data} = Transformer.handle_incoming(announce)
    Incoming.receive_activity(data)
  end

  test "a top-level post of ours, announced back by the community, is ingested", %{
    user: user,
    group: group
  } do
    post = publish_in(user, group, %{post_content: %{html_body: "<p>a post for the community</p>"}})

    assert {:ok, _} = receive_announce(announce_of(post))
  end

  test "a reply of ours, announced back by the community, is ingested", %{
    user: user,
    group: group
  } do
    parent = publish_in(user, group, %{post_content: %{html_body: "<p>the thread</p>"}})

    reply =
      publish_in(user, group, %{
        reply_to_id: uid(parent),
        post_content: %{html_body: "<p>a reply in it</p>"}
      })

    assert {:ok, _} = receive_announce(announce_of(reply))
  end
end
