defmodule Bonfire.Federate.ActivityPub.APReceiverWorker do
  @moduledoc """
  Process queued-up incoming activities using `Bonfire.Federate.ActivityPub.Receiver`
  """
  use ActivityPub.Workers.WorkerHelper, queue: "ap_incoming"

  @impl Oban.Worker

  def perform(%{args: %{"op" => "handle_activity", "activity" => activity}}) do
    Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity)
  end

  def perform(%{args: %{"op" => "handle_activity", "activity_id" => activity_id}}) do
    Bonfire.Federate.ActivityPub.Receiver.receive_activity(activity_id)
  end
end
