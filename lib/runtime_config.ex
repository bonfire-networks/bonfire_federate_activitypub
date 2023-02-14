defmodule Bonfire.Federate.ActivityPub.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  def config do
    import Config

    config :bonfire,
      # enable/disable logging of federation logic
      log_federation: true,
      federation_fallback_module: Bonfire.Social.APActivities
  end
end
