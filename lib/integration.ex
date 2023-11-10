# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_federate_activitypub)

defmodule Bonfire.Federate.ActivityPub do
  import Untangle
  alias Bonfire.Common.Config
  alias Bonfire.Common.Settings

  def repo, do: Config.repo()

  def disable(scope \\ :instance)

  def disable(:instance) do
    # Oban.cancel_all_jobs(Oban.Job)

    set_federating(:instance, false)
  end

  def disable(subject) do
    set_federating(subject, false)
  end

  def set_federating(:instance, set) do
    # Oban.cancel_all_jobs(Oban.Job)

    Settings.set([activity_pub: [instance: [federating: set]]],
      scope: :instance,
      skip_boundary_check: true
    )
  end

  def set_federating(subject, set) do
    Settings.set([activity_pub: [user_federating: set]],
      scope: subject,
      skip_boundary_check: true
    )
  end

  def federating?(subject \\ nil)

  def federating?(nil) do
    Bonfire.Common.Extend.module_enabled?(ActivityPub) and
      ActivityPub.Config.federating?()
  end

  def federating?(subject) do
    if Bonfire.Common.Extend.module_enabled?(ActivityPub) do
      case ActivityPub.Config.federating?() do
        #  enabled
        true ->
          case user_federating?(subject) do
            :not_set -> true
            :manual -> nil
            other -> other
          end

        #  manual mode
        nil ->
          case user_federating?(subject) do
            :not_set -> nil
            :manual -> nil
            # manual overrides auto
            true -> nil
            other -> other
          end

        false ->
          false
      end
    else
      false
    end
  end

  defp user_federating?(subject, default \\ :not_set) do
    Settings.get([:activity_pub, :user_federating], default,
      current_user: subject,
      one_scope_only: true,
      preload: true
    )
    |> debug()
  end
end
