defmodule Bonfire.Federate.ActivityPub.ServiceActorTest do
  @moduledoc """
  The instance's own service actor ("Federation Bot"), which is what incoming handling falls back to when a document names no author.

  Every Bonfire instance uses the SAME hardcoded id for its service character (`AdapterUtils.service_character_id/0`), so another instance's service actor can federate in and occupy that pointer here, and `Actor.get(pointer: …)` looks in `ap_object` (remote objects) before asking the adapter. Whatever else happens, this must never hand back a remote actor: doing so attributes locally-created activities to a bot on someone else's server.

  The collision is reported with `err/2`, which raises in dev/test (so it is fixed at source) and logs in prod (where the local service character is used instead).
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  import Tesla.Mock
  import Ecto.Query

  alias Bonfire.Federate.ActivityPub.Adapter
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @remote_instance "https://mocked.local"
  @remote_actor @remote_instance <> "/users/karen"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  test "is local" do
    assert {:ok, %ActivityPub.Actor{local: true}} = Adapter.get_or_create_service_actor()
  end

  test "raises when a remote actor occupies the shared service character id" do
    # make sure ours exists first, so the id below is genuinely contested rather than merely free
    assert {:ok, %ActivityPub.Actor{local: true}} = Adapter.get_or_create_service_actor()

    # reproduce the collision: a federated-in remote service actor stored under the shared id
    {:ok, remote} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @remote_actor)
    squat_service_character_id(remote)

    # `err/2` raises in dev/test so this gets fixed at source rather than quietly tolerated; in
    # prod it logs and falls through to the local service character below
    assert_raise RuntimeError, ~r/non-local actor occupying the service character id/, fn ->
      Adapter.get_or_create_service_actor()
    end
  end

  defp squat_service_character_id(remote_actor) do
    {:ok, object} = ActivityPub.Object.get_cached(ap_id: ActivityPub.Utils.ap_id(remote_actor))

    {1, _} =
      Bonfire.Common.Repo.update_all(
        from(o in ActivityPub.Object, where: o.id == ^object.id),
        set: [pointer_id: AdapterUtils.service_character_id()]
      )

    ActivityPub.Utils.cache_clear()
  end
end
