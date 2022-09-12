import Config

alias Bonfire.Federate.ActivityPub.Adapter

actor_types = ["Person", "Group", "Application", "Service", "Organization"]

config :bonfire,
  federation_search_path: [],
  # enable/disable logging of federation logic
  log_federation: true

config :bonfire, actor_AP_types: actor_types

# config :bonfire, Bonfire.Instance,
# hostname: hostname,
# description: desc
