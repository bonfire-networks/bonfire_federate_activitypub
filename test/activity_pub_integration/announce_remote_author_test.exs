defmodule Bonfire.Federate.ActivityPub.AnnounceRemoteAuthorTest do
  @moduledoc """
  A remote actor boosts (`Announce`) a remote post that we don't have yet. We fetch the post, and its author is the actor in its `attributedTo`, not the instance's service actor, which is only the author when the real one can't be resolved.

  The post can reach us in different shapes, which take different paths to its author: referenced by id or embedded in the `Announce`, with `attributedTo` as an actor id or as an embedded actor object.
  """
  # `@moduletag :federation` comes with this case
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Data.Social.Created
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Social.Boosts
  alias ActivityPub.Federator.Transformer

  @author "https://author.local/users/ann"
  @booster "https://booster.local/users/bob"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    actors =
      Map.new([{@author, "ann"}, {@booster, "bob"}], fn {id, name} ->
        {id, Simulate.actor_json(id, name)}
      end)

    # the notes that the author's server serves, by AP id
    {:ok, served} = start_supervised({Agent, fn -> %{} end})

    mock_global(fn
      %{method: :get, url: url} when is_map_key(actors, url) ->
        json(actors[url])

      %{method: :get, url: url} ->
        case Agent.get(served, &Map.get(&1, url)) do
          nil -> %Tesla.Env{status: 404, body: ""}
          note -> json(note)
        end

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    %{served: served, actors: actors}
  end

  defp note(attributed_to) do
    %{
      "id" => "#{@author}/notes/#{System.unique_integer([:positive])}",
      "type" => "Note",
      "attributedTo" => attributed_to,
      "content" => "<p>boost me</p>",
      "to" => [@public],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  # the author's server serves the note, then the booster's Announce of it reaches our inbox
  defp announce(served, note, object) do
    Agent.update(served, &Map.put(&1, note["id"], note))

    assert {:ok, _} =
             Transformer.handle_incoming(
               %{
                 "@context" => "https://www.w3.org/ns/activitystreams",
                 "id" => "#{@booster}/announces/#{System.unique_integer([:positive])}",
                 "type" => "Announce",
                 "actor" => @booster,
                 "to" => [@public],
                 "object" => object
               },
               from_inbox: true,
               authenticated: :http_signature,
               signed_by: @booster
             )
  end

  defp assert_boosted_by_booster_and_authored_by_author(note_id) do
    assert {:ok, %{pointer_id: post_id}} = ActivityPub.Object.get_cached(ap_id: note_id)
    assert is_binary(post_id), "the boosted note was not stored as a local object"

    {:ok, author} = AdapterUtils.get_character_by_ap_id(@author)
    {:ok, booster} = AdapterUtils.get_character_by_ap_id(@booster)

    assert 1 == Boosts.count(booster, post_id), "no boost of the post by the booster"

    assert %Created{creator_id: creator_id} = repo().get(Created, post_id)

    refute creator_id == AdapterUtils.service_character_id(),
           "the boosted post's author is the service actor"

    assert creator_id == id(author)
  end

  test "the boosted post's author is its attributedTo actor, when the Announce references the post by id",
       %{served: served} do
    note = note(@author)
    announce(served, note, note["id"])
    assert_boosted_by_booster_and_authored_by_author(note["id"])
  end

  test "the boosted post's author is its attributedTo actor, when attributedTo is an embedded actor object",
       %{served: served, actors: actors} do
    note = note(actors[@author])
    announce(served, note, note["id"])
    assert_boosted_by_booster_and_authored_by_author(note["id"])
  end

  test "the boosted post's author is its attributedTo actor, when the post is embedded in the Announce",
       %{served: served} do
    note = note(@author)
    announce(served, note, note)
    assert_boosted_by_booster_and_authored_by_author(note["id"])
  end
end
