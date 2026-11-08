defmodule Bonfire.Federate.ActivityPub.MastodonReplyOnceTest do
  @moduledoc """
  A Mastodon reply to a post is stored once, however many routes it reaches us by: its author's `Create` in our inbox, and the post's `replies` collection when we fetch it.

  The fixture is a real capture (`fixtures/mastodon/create_reply.json`), re-pointed at a post of ours.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock
  import Ecto.Query

  alias ActivityPub.Federator.Fetcher
  alias ActivityPub.Federator.Transformer
  alias Bonfire.Federate.ActivityPub.Incoming
  alias Bonfire.Federate.ActivityPub.Simulate

  @fixtures Path.join([__DIR__, "..", "fixtures"])
  @author "https://mastodon.local/users/Gargron"
  @reply_text "Looking forward"

  setup do
    parent_author = fake_user!()

    {:ok, parent} =
      Bonfire.Posts.publish(
        current_user: parent_author,
        boundary: "public",
        post_attrs: %{post_content: %{html_body: "<p>a post of ours</p>"}}
      )

    {:ok, %{data: parent_data}} = ActivityPub.Object.get_cached(pointer: parent.id)

    parent_author_ap_id = Bonfire.Me.Characters.character_url(parent_author)

    # a captured Mastodon reply, re-pointed at the post of ours
    activity =
      fixture("mastodon", "create_reply.json")
      |> update_in(["cc"], &swap(&1, parent_author_ap_id))
      |> update_in(["object", "cc"], &swap(&1, parent_author_ap_id))
      |> put_in(["object", "inReplyTo"], parent_data["id"])
      |> put_in(["object", "inReplyToAtomUri"], parent_data["id"])
      |> put_in(["object", "tag"], [
        %{"type" => "Mention", "href" => parent_author_ap_id, "name" => "@parent"}
      ])

    reply = activity["object"]

    reply_id = reply["id"]

    # whether the reply's server serves it, which a test turns off to have the reply "not arrived yet"
    {:ok, online} = start_supervised({Agent, fn -> true end})

    mock_global(fn
      %{method: :get, url: @author} ->
        json(person_actor(@author))

      %{method: :get, url: ^reply_id} ->
        if Agent.get(online, & &1), do: json(reply), else: %Tesla.Env{status: 404, body: ""}

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    # the parent as its server presents it: with the collection of its replies
    parent_with_replies =
      Map.put(parent_data, "replies", %{
        "id" => parent_data["id"] <> "/replies",
        "type" => "Collection",
        "first" => %{
          "type" => "CollectionPage",
          "partOf" => parent_data["id"] <> "/replies",
          "items" => [reply["id"]]
        }
      })

    %{activity: activity, reply: reply, parent: parent_with_replies, online: online}
  end

  # a reply to the Mastodon reply, delivered while that one is not served: it waits under a placeholder for it
  defp deliver_child_of(reply) do
    child_id = "#{@author}/statuses/child-#{System.unique_integer([:positive])}"

    deliver(%{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => child_id <> "/activity",
      "type" => "Create",
      "actor" => @author,
      "to" => ["https://www.w3.org/ns/activitystreams#Public"],
      "object" => %{
        "id" => child_id,
        "type" => "Note",
        "attributedTo" => @author,
        "content" => "<p>a reply to the reply</p>",
        "inReplyTo" => reply["id"],
        "to" => ["https://www.w3.org/ns/activitystreams#Public"],
        "published" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    })
  end

  # delivered to our inbox
  defp deliver(activity) do
    assert {:ok, activity} = Transformer.handle_incoming(activity)
    assert {:ok, %{id: _}} = Incoming.receive_activity(activity)
  end

  # the Posts that hold the reply's text, whether or not they are linked to its AP id
  defp posts_with_text do
    from(p in Bonfire.Data.Social.Post,
      join: c in Bonfire.Data.Social.PostContent,
      on: c.id == p.id,
      where: like(c.html_body, ^"%#{@reply_text}%"),
      select: p.id
    )
    |> repo().all()
  end

  # the records that carry the AP id as their canonical URI
  defp records_with_ap_id(ap_id) do
    from(p in Bonfire.Data.ActivityPub.Peered, where: p.canonical_uri == ^ap_id, select: p.id)
    |> repo().all()
  end

  test "a reply we received and then fetch from its parent's replies is stored once", %{
    activity: activity,
    reply: reply,
    parent: parent
  } do
    deliver(activity)

    assert [_one] = posts_with_text(), "control: the delivered reply is stored"

    Fetcher.fetch_replies(parent, fetch_collection_entries: true, fetch_collection: true)

    assert [_one] = posts_with_text(),
           "the reply must still be one Post once the parent's replies are fetched"

    assert [_one] = records_with_ap_id(reply["id"]),
           "and one record must carry its AP id"
  end

  describe "when a reply to the reply made a placeholder for it" do
    test "the reply fetched from its parent's replies, then received, is stored once", %{
      activity: activity,
      reply: reply,
      parent: parent,
      online: online
    } do
      Agent.update(online, fn _ -> false end)
      deliver_child_of(reply)

      assert Bonfire.Federate.ActivityPub.AdapterUtils.placeholder_id(reply["id"]),
             "control: a placeholder stands in for the reply"

      Agent.update(online, fn _ -> true end)
      Fetcher.fetch_replies(parent, fetch_collection_entries: true, fetch_collection: true)
      deliver(activity)

      assert [_one] = posts_with_text(), "the reply must be one Post"
      assert [_one] = records_with_ap_id(reply["id"]), "and one record must carry its AP id"
    end

    test "the reply received, then fetched from its parent's replies, is stored once", %{
      activity: activity,
      reply: reply,
      parent: parent,
      online: online
    } do
      Agent.update(online, fn _ -> false end)
      deliver_child_of(reply)

      assert Bonfire.Federate.ActivityPub.AdapterUtils.placeholder_id(reply["id"]),
             "control: a placeholder stands in for the reply"

      Agent.update(online, fn _ -> true end)
      deliver(activity)
      Fetcher.fetch_replies(parent, fetch_collection_entries: true, fetch_collection: true)

      assert [_one] = posts_with_text(), "the reply must be one Post"
      assert [_one] = records_with_ap_id(reply["id"]), "and one record must carry its AP id"
    end
  end

  defp swap(list, replacement) when is_list(list) do
    Enum.map(list, fn
      "https://kind.local/users/TheLongestJohns" -> replacement
      other -> other
    end)
  end

  defp fixture(dir, name) do
    @fixtures |> Path.join(dir) |> Path.join(name) |> File.read!() |> Jason.decode!()
  end

  # `Simulate.actor_json/1` only answers for a handful of fixed ids, so rebase one onto the actor a fixture names
  defp person_actor(ap_id) do
    Simulate.actor_json("https://mocked.local/users/karen")
    |> Map.merge(%{
      "id" => ap_id,
      "type" => "Person",
      "preferredUsername" => ap_id |> String.split("/") |> List.last(),
      "inbox" => "#{ap_id}/inbox",
      "outbox" => "#{ap_id}/outbox"
    })
    |> put_in(["publicKey", "id"], "#{ap_id}#main-key")
    |> put_in(["publicKey", "owner"], ap_id)
  end
end
