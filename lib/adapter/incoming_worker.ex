defmodule Bonfire.Federate.ActivityPub.Incoming.Worker do
  @moduledoc """
  Process queued-up incoming activities using `Bonfire.Federate.ActivityPub.Incoming`
  """
  use ActivityPub.Workers.WorkerHelper, queue: "ap_incoming"

  @impl Oban.Worker

  def perform(%{args: %{"op" => "handle_activity", "activity" => activity}}) do
    Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
  end

  def perform(%{
        args: %{"op" => "handle_activity", "activity_id" => activity_id}
      }) do
    Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity_id)
  end
end
