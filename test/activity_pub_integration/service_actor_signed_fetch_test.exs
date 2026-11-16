defmodule Bonfire.Federate.ActivityPub.ServiceActorSignedFetchTest do
  @moduledoc """
  A signed fetch is signed as the instance's service actor. That actor must be loadable when the actor cache is cold (the first fetch after a boot or a cache clear), with the signing on, as it is by default.
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false

  @moduletag :federation

  import Tesla.Mock
  import ActivityPub.Test.Helpers, only: [clear_config: 1, clear_config: 2]

  alias Bonfire.Federate.ActivityPub.Adapter

  @remote_actor "https://signed-fetch.local/users/karen"

  setup_all do
    mock_global(fn
      %{method: :get, url: @remote_actor, headers: headers} ->
        # only a signed fetch gets the document
        if List.keymember?(headers, "signature", 0),
          do: json(Simulate.actor_json(@remote_actor, "karen")),
          else: %Tesla.Env{status: 401, body: "signature required"}

      env ->
        apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)
  end

  setup do
    Process.put(:federating, true)
    clear_config([:sign_object_fetches], true)
    :ok
  end

  test "a signed fetch works with the service actor not in the actor cache" do
    # make sure the service character exists, then forget it is cached, so that it is loaded from the database by the adapter
    assert {:ok, %ActivityPub.Actor{local: true}} = Adapter.get_or_create_service_actor()
    ActivityPub.Utils.cache_clear()

    assert {:ok, %{data: %{"id" => @remote_actor}}} =
             ActivityPub.Federator.Fetcher.fetch_object_from_id(@remote_actor)
  end
end
