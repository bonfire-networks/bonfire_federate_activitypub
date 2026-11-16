defmodule Bonfire.Federate.ActivityPub.FetchBodyCapTest do
  @moduledoc """
  The ActivityPub fetcher reads documents from servers that anyone can run, so a server that answers with a body over the size limit (`config :activity_pub, :http, max_body_bytes`, 10 MB by default, as for `Bonfire.Common.HTTP`) must not get its document read and stored: an answer over the limit is an error and nothing is kept. An ordinary document comes through. The HTTP adapter is mocked, so the answers are made up here; this checks that the limit applies, not that the body is not held in memory while it is read.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias ActivityPub.Federator.Fetcher

  @public "https://www.w3.org/ns/activitystreams#Public"
  @author "https://author.local/users/ana"
  # the limit for these tests, far under the default so the documents stay small
  @cap 4_000

  setup do
    # the AP library reads its own limit (`config :activity_pub, :http, max_body_bytes`)
    initial = ActivityPub.Config.get([:http, :max_body_bytes])
    ActivityPub.Config.put([:http, :max_body_bytes], @cap)

    on_exit(fn ->
      ActivityPub.Config.put([:http, :max_body_bytes], initial)
    end)

    {:ok, served} = start_supervised({Agent, fn -> %{} end})

    mock(fn
      %{method: :get, url: @author} ->
        json(Simulate.actor_json(@author, "ana"))

      %{method: :get, url: url} ->
        case Agent.get(served, &Map.get(&1, url)) do
          nil -> %Tesla.Env{status: 404, body: ""}
          doc -> json(doc)
        end
    end)

    {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @author)

    %{served: served}
  end

  defp serve(served, content) do
    id = "https://author.local/notes/#{System.unique_integer([:positive])}"

    Agent.update(served, fn docs ->
      Map.put(docs, id, %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => id,
        "type" => "Note",
        "attributedTo" => @author,
        "to" => [@public],
        "published" => "2026-08-25T19:05:56Z",
        "content" => content
      })
    end)

    id
  end

  test "control: a small document is fetched and stored", %{served: served} do
    id = serve(served, "<p>an ordinary note</p>")

    assert {:ok, %{data: %{"id" => ^id}}} = Fetcher.fetch_object_from_id(id)
    assert {:ok, _} = ActivityPub.Object.get_cached(ap_id: id)
  end

  test "a document over the size limit is an error and nothing is stored", %{served: served} do
    id = serve(served, "<p>" <> String.duplicate("a", 5 * @cap) <> "</p>")

    refute match?({:ok, _}, Fetcher.fetch_object_from_id(id)),
           "a document over #{@cap} bytes was fetched"

    assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: id)
  end
end
