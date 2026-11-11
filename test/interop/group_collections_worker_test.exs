defmodule Bonfire.Federate.ActivityPub.GroupCollectionsWorkerTest do
  @moduledoc """
  A collection of a group we mirror (its moderators, its topics), fetched by the generic fetch job (`RemoteFetcherWorker`, op `fetch_collection`), reaches the module that claims its type through `handle_remote_collection/2`, as the group's members do.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Tesla.Mock

  alias Bonfire.Classify.Categories
  alias Bonfire.Federate.ActivityPub.AdapterUtils
  alias Bonfire.Federate.ActivityPub.Simulate, as: APSimulate

  @group "https://threads.local/c/cooks"
  @moderators "https://threads.local/c/cooks/moderators"
  @narrower "https://threads.local/c/cooks/narrower"
  @moderator "https://threads.local/u/head_cook"
  @topic "https://threads.local/c/cooks_harvest"

  setup do
    group =
      APSimulate.actor_json(@group, "cooks", %{
        "type" => "Group",
        "openness" => "open",
        "attributedTo" => @moderators,
        "narrower" => @narrower
      })

    topic =
      APSimulate.actor_json(@topic, "cooks_harvest", %{
        "type" => "Group",
        "broader" => @group,
        "inScheme" => "https://w3id.org/fep/9b2b#Topic"
      })

    collection = fn id, items ->
      %{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "id" => id,
        "type" => "OrderedCollection",
        "totalItems" => length(items),
        "orderedItems" => items
      }
    end

    # the group alone at first, so making the mirror lists nobody and files no topic
    mock(fn
      %{method: :get, url: @group} -> json(group)
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, mirror} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(group)
    {:ok, mirror} = Categories.get(id(mirror), skip_boundary_check: true)

    mock(fn
      %{method: :get, url: @group} -> json(group)
      %{method: :get, url: @topic} -> json(topic)
      %{method: :get, url: @moderator} -> json(APSimulate.actor_json(@moderator, "head_cook"))
      %{method: :get, url: @moderators} -> json(collection.(@moderators, [@moderator]))
      %{method: :get, url: @narrower} -> json(collection.(@narrower, [@topic]))
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    %{mirror: mirror}
  end

  defp fetch_job(id, type) do
    ActivityPub.Federator.Workers.RemoteFetcherWorker.enqueue("fetch_collection", %{
      "id" => id,
      "collection_type" => type,
      "owner" => @group
    })

    Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)
  end

  test "a fetched moderators collection makes the people it lists the mirror's moderators", %{
    mirror: mirror
  } do
    assert Categories.moderators(mirror) == [], "control: nobody is listed before the fetch"

    fetch_job(@moderators, "moderators")

    assert {:ok, moderator} = AdapterUtils.get_character_by_ap_id(@moderator)
    assert Categories.listed_moderator?(moderator, mirror)
  end

  test "a fetched narrower collection mirrors the topics it lists, filed in the group", %{
    mirror: mirror
  } do
    refute match?({:ok, _}, AdapterUtils.get_character_by_ap_id(@topic)),
           "control: the topic is not here before the fetch"

    fetch_job(@narrower, "narrower")

    assert {:ok, %Bonfire.Classify.Category{type: :topic} = topic} =
             AdapterUtils.get_character_by_ap_id(@topic)

    assert topic |> repo().preload(:tree, force: true) |> e(:tree, :parent_id, nil) == id(mirror)
  end
end
