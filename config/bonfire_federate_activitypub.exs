import Config

alias Bonfire.Federate.ActivityPub.Adapter

actor_types = ["Person", "Group", "Application", "Service", "Organization"]

config :bonfire,
  federation_search_path: [
    ],
  log_federation: true # enable/disable logging of federation logic

config :bonfire, actor_AP_types: actor_types

# config :bonfire, Bonfire.Instance,
  # hostname: hostname,
  # description: desc
