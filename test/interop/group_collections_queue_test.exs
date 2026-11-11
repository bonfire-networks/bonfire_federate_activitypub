defmodule Bonfire.Federate.ActivityPub.GroupCollectionsQueueTest do
  @moduledoc """
  What makes us read a mirrored group's moderators and topics (the mirror being made, someone here following or joining it) queues the generic fetch job rather than fetching inline, and the job's result is applied by `handle_remote_collection/2`. So nothing is listed until the queue runs.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  use Oban.Testing, repo: repo()

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

    # everything served from the start, so an inline sync would have listed it all by the time the mirror is made
    mock(fn
      %{method: :get, url: @group} -> json(group)
      %{method: :get, url: @topic} -> json(topic)
      %{method: :get, url: @moderator} -> json(APSimulate.actor_json(@moderator, "head_cook"))
      %{method: :get, url: @moderators} -> json(collection.(@moderators, [@moderator]))
      %{method: :get, url: @narrower} -> json(collection.(@narrower, [@topic]))
      %{method: :post} -> %Tesla.Env{status: 202, body: ""}
      %{method: :get} -> %Tesla.Env{status: 404, body: ""}
    end)

    {:ok, mirror} = Bonfire.Federate.ActivityPub.Adapter.maybe_create_remote_actor(group)
    {:ok, mirror} = Categories.get(id(mirror), skip_boundary_check: true)

    %{mirror: mirror}
  end

  defp collection_jobs do
    all_enqueued(worker: ActivityPub.Federator.Workers.RemoteFetcherWorker)
    |> Enum.filter(&(&1.args["op"] == "fetch_collection"))
    |> Map.new(&{&1.args["id"], &1.args["collection_type"]})
  end

  test "making a mirror queues a fetch of its moderators, which lists them once it runs", %{
    mirror: mirror
  } do
    assert collection_jobs()[@moderators] == "moderators"
    assert Categories.moderators(mirror) == [], "listed before the queue ran"

    Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

    assert {:ok, moderator} = AdapterUtils.get_character_by_ap_id(@moderator)
    assert Categories.listed_moderator?(moderator, mirror)
  end

  test "making a mirror queues a fetch of its topics, which are mirrored once it runs", %{
    mirror: mirror
  } do
    assert collection_jobs()[@narrower] == "narrower"

    refute match?({:ok, _}, AdapterUtils.get_character_by_ap_id(@topic)),
           "listed before the queue ran"

    Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)

    assert {:ok, %Bonfire.Classify.Category{type: :topic} = topic} =
             AdapterUtils.get_character_by_ap_id(@topic)

    assert topic |> repo().preload(:tree, force: true) |> e(:tree, :parent_id, nil) == id(mirror)
  end

  # the interval of the sync is taken once the job ran, so the next trigger after that waits, and one after it is let pass queues again
  test "someone here following the mirror queues a fetch of its topics when the interval has passed",
       %{mirror: mirror} do
    Oban.drain_queue(queue: :remote_fetcher, with_recursion: true)
    refute Map.has_key?(collection_jobs(), @narrower), "control: nothing waiting"

    assert {:ok, _} = Categories.follow_group(fake_user!(), mirror)
    refute Map.has_key?(collection_jobs(), @narrower), "queued again within the interval"

    Bonfire.Common.Cache.remove("remote_children_sync:#{id(mirror)}")
    assert {:ok, _} = Categories.follow_group(fake_user!(), mirror)

    assert collection_jobs()[@narrower] == "narrower"
  end
end
