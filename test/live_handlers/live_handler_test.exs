defmodule Bonfire.Federate.ActivityPub.LiveHandlerTest do
  use Bonfire.Federate.ActivityPub.DataCase, async: false
  import Tesla.Mock

  alias Bonfire.Federate.ActivityPub.LiveHandler

  @remote_actor "https://mocked.local/users/karen"

  setup do
    mock(fn
      %{method: :get, url: @remote_actor} ->
        json(Simulate.actor_json(@remote_actor))
    end)
  end

  describe "handle_event/3 refetch_profile" do
    test "enqueues a background fetch for a remote actor by ULID" do
      {:ok, user} = Simulate.fake_remote_user(@remote_actor)
      id = id(user)

      assert {:noreply, _socket} =
               LiveHandler.handle_event("refetch_profile:#{id}", %{}, build_socket())

      Oban.Testing.assert_enqueued(repo(),
        worker: ActivityPub.Federator.Workers.RemoteFetcherWorker,
        args: %{"op" => "fetch_remote", "id" => @remote_actor}
      )
    end

    test "does not enqueue a fetch for a local user" do
      local_user = fake_user!("local_refetch_test")
      id = local_user.id

      assert {:noreply, _socket} =
               LiveHandler.handle_event("refetch_profile:#{id}", %{}, build_socket())

      Oban.Testing.refute_enqueued(repo(),
        worker: ActivityPub.Federator.Workers.RemoteFetcherWorker
      )
    end

    test "handles unknown ULID gracefully without raising" do
      fake_ulid = Needle.ULID.generate()

      assert {:noreply, _socket} =
               LiveHandler.handle_event("refetch_profile:#{fake_ulid}", %{}, build_socket())
    end
  end

  defp build_socket, do: %Phoenix.LiveView.Socket{}
end
