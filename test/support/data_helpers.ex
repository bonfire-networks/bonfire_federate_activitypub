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
    {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)

    %{
      "actor" => local_actor.ap_id,
      "to" => to
    }
  end
  def local_activity_json_to(to) do
    local_activity_json_to([to])
  end

  def activity_json(actor) do
    %{"actor" => actor}
  end

  def remote_activity_json() do
    activity_json(@remote_actor)
  end

  def remote_actor_json(actor \\ @remote_actor) do
    %{
      "id" => actor,
      "type" => "Person"
    }
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
      to: to
    }
  end

  def remote_activity_json_to(to \\ nil) do

    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(@remote_actor)

    to = to || (
      local_user = fake_user!(@local_user)
      {:ok, local_actor} = ActivityPub.Adapter.get_actor_by_id(local_user.id)
      local_actor.ap_id
    )

    remote_activity_json(actor, to)
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

  def remote_actor_user(actor_uri \\ @remote_actor) do
    {:ok, actor} = ActivityPub.Actor.get_or_fetch_by_ap_id(actor_uri)
    {:ok, user} = Bonfire.Me.Users.by_username(actor.username)
    user
  end


end
