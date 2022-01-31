# check that this extension is configured
# Bonfire.Common.Config.require_extension_config!(:bonfire_federate_activitypub)

defmodule Bonfire.Federate.ActivityPub do
  alias Bonfire.Common.Config

  def repo, do: Config.get!(:repo_module)

  def is_admin?(user) do
    if Map.get(user, :instance_admin) do
      Map.get(user.instance_admin, :is_instance_admin)
    else
      false # FIXME
    end
  end
end
