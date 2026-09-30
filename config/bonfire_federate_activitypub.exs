import Config

alias Bonfire.Federate.ActivityPub.Adapter

actor_types = ["Person", "Group", "Application", "Service", "Organization"]

config :bonfire,
  # enable/disable logging of federation logic
  log_federation: true,
  federation_fallback_module: Bonfire.Social.APActivities

config :bonfire, actor_AP_types: actor_types

# Incoming activity types Bonfire does not model and skips cleanly (e.g. PeerTube `View`
# view-count pings) instead of erroring/retrying. See bonfire-app#1802.
config :bonfire_federate_activitypub, :skip_activity_types, ["View", "Listen", "WatchAction"]

# Each incoming `interactionPolicy` key, and the verbs it grants or denies (see `AdapterUtils.ap_incoming_interaction_policy_to_verb_grants/2`)
config :bonfire_federate_activitypub, :interaction_policy_verbs, %{
  "canLike" => [:like],
  "canAnnounce" => [:boost],
  "canReply" => [:reply],
  "canQuote" => [:quote]
}

# config :bonfire, Bonfire.Instance,
# hostname: hostname,
# description: desc
