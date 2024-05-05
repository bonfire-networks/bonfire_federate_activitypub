# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_federate_activitypub)

defmodule Bonfire.Federate.ActivityPub do
  @moduledoc "./README.md" |> File.stream!() |> Enum.drop(1) |> Enum.join()

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
    case federating_default?() do
      {:default, value} -> value
      {:override, value} -> value
    end
  end

  def federating?(subject) do
    case federating_default?() do
      {:override, value} ->
        value

      #  enabled
      {:default, true} ->
        case user_federating?(subject) do
          :not_set -> true
          :manual -> nil
          other -> other
        end

      #  manual mode
      {:default, nil} ->
        case user_federating?(subject) do
          :not_set -> nil
          :manual -> nil
          # manual overrides auto
          true -> nil
          other -> other
        end

      {:default, false} ->
        false
    end
    |> debug()
  end

  def federating_default?() do
    case Process.get(:federating) do
      nil ->
        {:default,
         Bonfire.Common.Extend.module_enabled?(ActivityPub) and
           ActivityPub.Config.federating?()}

      other ->
        {:override, other}
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
