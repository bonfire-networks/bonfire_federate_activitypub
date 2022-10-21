defmodule Bonfire.Federate.ActivityPub.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  def config do
    import Config

    config :bonfire,
      federation_search_path: [
        :bonfire_common,
        :bonfire_me,
        :bonfire_social,
        :bonfire_valueflows,
        :bonfire_classify,
        :bonfire_geolocate,
        :bonfire_quantify
      ],
      # enable/disable logging of federation logic
      log_federation: true,
      federation_fallback_module: Bonfire.Social.APActivities
  end
end
