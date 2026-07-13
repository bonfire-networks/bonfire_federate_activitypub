defmodule Bonfire.Federate.ActivityPub.RuntimeConfig do
  @behaviour Bonfire.Common.ConfigModule
  def config_module, do: true

  def config do
    import Config

    config :bonfire,
      # enable/disable logging of federation logic
      log_federation: true,
      federation_fallback_module: Bonfire.Social.APActivities,
      # Well-known singleton actors that must ALWAYS keep their stable username-based AP URL,
      # never the ULID scheme (see Bonfire.Common.URIs `new_actor_scheme?/1`). The service /
      # instance actor has a hand-crafted id that sorts after real ULIDs, so without this it
      # would be wrongly treated as a "new" actor once a `:ulid_actor_ids_since` cutoff is set.
      reserved_username_actor_ids: [
        Bonfire.Federate.ActivityPub.AdapterUtils.service_character_id()
      ]

    # Auto-record (once, at each instance's first boot with this code) the per-instance cutoff
    # that switches NEW actors to the ULID-based AP URL scheme — see `new_actor_scheme?/1` in
    # `Bonfire.Common.URIs` and `Bonfire.Common.Settings.IdCutoffs`. Existing actors keep their
    # username URLs forever. Keyword list so declarations from other extensions deep-merge.
    config :bonfire_common, Bonfire.Common.Settings.IdCutoffs,
      record: [ulid_actor_ids_since: true]
  end
end
