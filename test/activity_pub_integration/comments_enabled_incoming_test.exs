defmodule Bonfire.Federate.ActivityPub.CommentsEnabledIncomingTest do
  @moduledoc """
  An incoming object's `commentsEnabled` (PeerTube, Pixelfed, Mobilizon, …): `false` closes its thread here (`Blocks.lock/2`), and an `Update` saying `true` reopens it (`Threads.ap_receive_comments_enabled/4`).
  """
  use Bonfire.Federate.ActivityPub.ConnCase, async: false
  @moduletag :federation
  import Tesla.Mock

  alias Bonfire.Boundaries

  @actor "https://mocked.local/users/karen"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup_all do
    mock_global(fn
      %{method: :get, url: @actor} -> json(Simulate.actor_json(@actor))
      env -> apply(ActivityPub.Test.HttpRequestMock, :request, [env])
    end)

    :ok
  end

  setup do
    Process.put(:federating, true)
    :ok
  end

  defp note(id, comments_enabled) do
    %{
      "type" => "Note",
      "id" => id,
      "attributedTo" => @actor,
      "content" => "a note",
      "to" => [@public],
      "published" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "commentsEnabled" => comments_enabled
    }
  end

  defp receive_incoming(type, object) do
    {:ok, data} =
      ActivityPub.Federator.Transformer.handle_incoming(%{
        "@context" => "https://www.w3.org/ns/activitystreams",
        "type" => type,
        "id" => "#{object["id"]}/#{String.downcase(type)}/#{Needle.UID.generate()}",
        "actor" => @actor,
        "to" => [@public],
        "object" => object
      })

    {:ok, received} = Bonfire.Federate.ActivityPub.Incoming.receive_activity(data)
    received
  end

  test "a note arriving with comments disabled is locked, and an Update enabling them reopens it" do
    id = "#{@actor}/notes/#{Needle.UID.generate()}"
    someone = fake_user!()

    post = receive_incoming("Create", note(id, false))
    refute Boundaries.can?(someone, :reply, post), "closed, as it arrived"

    receive_incoming("Update", note(id, true))
    assert Boundaries.can?(someone, :reply, post), "reopened by the update"
  end
end
