# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_federate_activitypub)

defmodule Bonfire.Federate.ActivityPub do
  alias Bonfire.Common.Config

  def repo, do: Config.repo()

  def disable() do
    Bonfire.Me.Settings.set([activity_pub: [instance: [federating: false]]],
      scope: :instance,
      skip_boundary_check: true
    )

    # Oban.cancel_all_jobs(Oban.Job)
  end
end
