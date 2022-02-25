defmodule Bonfire.Federate.ActivityPub.DataHelpers do
  use Bonfire.Common.Utils
  import Bonfire.Me.Fake
  alias Bonfire.Federate.ActivityPub.Simulate

  @remote_actor "https://kawen.space/users/karen"
  @local_actor "alice"
  @public_uri "https://www.w3.org/ns/activitystreams#Public"

  def local_activity_json_to(to \\ @remote_actor)
  def local_activity_json_to(to) when is_list(to) do
    local_user = fake_user!(@local_actor)
    local_activity_json(local_user, to)
  end
  def local_activity_json_to(to) do
    local_activity_json_to([to])
  end

  def local_activity_json(local_user, to) do
    {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)

    %{
      actor: local_actor.ap_id,
      to: to,
      # local: true
    }
  end

  def activity_json(actor) do
    %{"actor" => actor}
  end

  def remote_activity_json() do
    activity_json(@remote_actor)
  end

  def remote_activity_json(actor, to) do
    context = "blabla"

    object = %{
      "content" => "content",
      "type" => "Note"
    }

    %{
      actor: actor,
      context: context,
      object: object,
      to: to,
      local: false
    }
  end

  def local_actor_ids(to) when is_list(to), do: Enum.map(to, &local_actor_ids/1)
  def local_actor_ids(nil), do: fake_user!(@local_actor) |> local_actor_ids()
  def local_actor_ids(%Bonfire.Data.Identity.User{id: id}), do: ActivityPub.Adapter.get_actor_by_id(id) ~> local_actor_ids()
  def local_actor_ids(%{ap_id: ap_id}), do: ap_id
  def local_actor_ids(ap_id) when is_binary(ap_id), do: ap_id

  def remote_activity_json_to(to \\ nil)
  def remote_activity_json_to(to) do

    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)

    local_actor_ids(to)
    |> dump("local_actor_ids")
    |> remote_activity_json(actor.ap_id, ...)
  end

  def receive_remote_activity_to(to) when not is_list(to), do: receive_remote_activity_to([to])
  def receive_remote_activity_to(to) do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)
    recipient_actors = Enum.map(to, &recipient/1)
    params = remote_activity_json(actor, recipient_actors)
    with {:ok, activity} <- ActivityPub.create(params), do:
      {:ok, post} = Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)
  end

  defp recipient(%{id: _} = recipient) do
    ActivityPub.Actor.get_by_local_id!(recipient.id).ap_id
  end
  defp recipient(%{ap_id: actor}) do
    actor
  end
  defp recipient(actor) do
    actor
  end

  def remote_actor_json(actor \\ @remote_actor) do
    %{
      "id" => actor,
      "type" => "Person"
    }
  end

  def remote_actor_user(actor_uri \\ @remote_actor) do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(actor_uri)
    {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    user
  end


end
