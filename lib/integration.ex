# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_federate_activitypub)

defmodule Bonfire.Federate.ActivityPub do
  alias Bonfire.Common.Config
  alias Bonfire.Common.Settings

  def repo, do: Config.repo()

  def disable(scope \\ :instance) do
    # if scope == :instance, do: Oban.cancel_all_jobs(Oban.Job)

    Bonfire.Common.Settings.set([activity_pub: [instance: [federating: false]]],
      scope: scope,
      skip_boundary_check: true
    )
  end

  def federating?(subject \\ nil) do
    Bonfire.Common.Extend.module_enabled?(ActivityPub) and
      ActivityPub.Config.federating?() and
      Settings.get([:activity_pub, :instance, :federating], nil,
        current_user: subject,
        one_scope_only: true,
        preload: true
      ) != false
  end
end
