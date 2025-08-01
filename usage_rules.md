# Bonfire.Federate.ActivityPub Usage Rules and Documentation

## Overview

This extension provides the adapter implementation that connects Bonfire with the ActivityPub federation protocol. It serves as the bridge between Bonfire's data models, boundaries system, and user concepts with the ActivityPub specification, enabling federated social interactions across the fediverse.

**Key Responsibilities:**
- Implements the ActivityPub adapter behavior required by the core `activity_pub` library
- Translates between Bonfire's data structures and ActivityPub's JSON-LD format
- Integrates federation with Bonfire's boundaries system for privacy and moderation
- Manages remote instances and actors (Peer/Peered relationships)
- Routes activities to appropriate Bonfire modules for processing

## Architecture

### Core Components

```
Bonfire.Federate.ActivityPub
├── Adapter                 # Main adapter implementation
├── Incoming               # Processes incoming federated activities
├── Outgoing              # Handles outgoing federation
├── AdapterUtils          # Helper functions for data conversion
├── BoundariesMRF         # Message Rewrite Facility for boundaries
├── FederationModules     # Activity routing system
└── Peer/Peered          # Remote instance/actor management
```

### Data Flow

1. **Incoming**: ActivityPub → Adapter → Incoming → FederationModules → Bonfire Contexts
2. **Outgoing**: Bonfire Events → Outgoing → ActivityPub → Remote Instances

## Adapter Implementation

The adapter (`Bonfire.Federate.ActivityPub.Adapter`) implements all required callbacks from `ActivityPub.Federator.Adapter`:

### Actor Management

```elixir
# Get actor by different identifiers
get_actor_by_id(id)        # By internal Bonfire ID
get_actor_by_username(username)  # By username
get_actor_by_ap_id(ap_id)       # By ActivityPub ID

# Actor updates
update_local_actor(actor, params)   # Update local actor with new data
update_remote_actor(actor)          # Update cached remote actor
maybe_create_remote_actor(actor)    # Create or get remote actor
```

### Activity Processing

```elixir
# Main activity handler - delegates to Incoming module
handle_activity(activity) 
  → Incoming.receive_activity(activity)
    → FederationModules.federation_module(activity_type)
      → ContextModule.ap_receive_activity(character, activity, object)
```

### Social Graph

```elixir
# Get followers/following for federation
get_follower_local_ids(actor, purpose)
get_following_local_ids(actor, purpose)
external_followers_for_activity(actor, activity) # Filters by boundaries
```

### Federation Control

```elixir
# Check if actor/content should federate
federate_actor?(actor, direction, by_actor)
  - Checks user federation settings
  - Applies boundary blocks
  - Considers instance-wide settings
```

## Character/Actor Conversion

Bonfire Characters (users, groups, etc.) are converted to ActivityPub Actors:

```elixir
# Character → Actor conversion
character_to_actor(character) → %ActivityPub.Actor{
  id: character.id,
  data: %{
    "id" => "https://instance.com/pub/actors/username",
    "type" => "Person",
    "preferredUsername" => username,
    "inbox" => "https://instance.com/pub/actors/username/inbox",
    "outbox" => "https://instance.com/pub/actors/username/outbox",
    # ... other AP properties
  },
  local: true,
  keys: pem_keys,
  pointer_id: character.id
}
```

## Incoming Federation

The `Incoming` module processes federated activities through a pattern-matching pipeline:

### Activity Routing

1. **Extract activity and object types**
2. **Find appropriate handler** via `FederationModules`
3. **Delegate to context module** (e.g., `Bonfire.Social.Boosts.ap_receive_activity`)
4. **Fallback to generic handler** if no specific handler found

### Key Functions

```elixir
# Main entry point
receive_activity(activity)

# Activity type matching
receive_activity(%{data: %{"type" => "Create"}}, %{data: %{"type" => "Note"}})
  → Bonfire.Social.Posts.ap_receive_activity(character, activity, object)

receive_activity(%{data: %{"type" => "Follow"}}, object)
  → Bonfire.Social.Graph.Follows.ap_receive_activity(character, activity, object)
```

### Object Creation

For Create activities, the module:
1. Generates appropriate pointer IDs based on published date
2. Creates local representation of remote object
3. Saves canonical URI mapping via Peered
4. Updates ActivityPub object cache with pointer_id

## Outgoing Federation

The `Outgoing` module handles publishing local activities:

### Federation Decision

```elixir
maybe_federate(subject, verb, object, opts)
  - Check if subject/object is local
  - Check federation settings
  - Check boundaries
  - Route to appropriate handler
```

### Activity Publishing

```elixir
prepare_and_queue(subject, verb, object, opts)
  → FederationModules.federation_module({verb, object_type})
    → Module.ap_publish_activity(subject, verb, object)
      → ActivityPub.create/follow/like/announce/etc.
```

### Special Cases

- **User deletion**: Publishes actor deletion
- **Updates**: Publishes actor updates
- **Local-only content**: Filtered by boundaries

## Boundaries Integration

### BoundariesMRF

Implements ActivityPub's Message Rewrite Facility to filter activities based on Bonfire's boundaries:

#### Block Types

1. **Ghost** (`:ghost`) - Complete blocking
   - Filters ghosted recipients from outgoing activities
   - Rejects follows from ghosted actors

2. **Silence** (`:silence`) - Limit visibility
   - Blocks follows to silenced actors
   - Filters recipients of incoming activities
   - Allows follows from silenced actors

3. **Block** (`:block`) - Traditional blocking
   - Complete activity rejection

#### Filtering Process

```elixir
BoundariesMRF.filter(activity, is_local?)
  1. Extract authors and recipients
  2. Check ghost blocks
  3. Check silence blocks
  4. Filter recipients based on blocks
  5. Accept, reject, or ignore activity
```

#### Instance Blocking

- Config-based regex blocking
- Database instance blocks via Peer
- User-specific instance blocks

## Instance & Peer Management

### Data Models

**Peer** - Represents a remote instance
```elixir
%Bonfire.Data.ActivityPub.Peer{
  host: "remote.instance",
  base_url: "https://remote.instance",
  display_hostname: "remote.instance"
}
```

**Peered** - Links remote actors/objects to their instance
```elixir
%Bonfire.Data.ActivityPub.Peered{
  id: local_pointer_id,
  peer: %Peer{},
  canonical_uri: "https://remote.instance/users/alice"
}
```

### Instance Circles

Remote actors are automatically added to instance-specific circles for boundary management:
- Allows per-instance moderation
- Enables instance-wide blocks/silences
- Provides federation statistics

## Configuration

### Instance-Wide Settings

```elixir
# Runtime configuration
config :bonfire,
  log_federation: true,
  federation_fallback_module: Bonfire.Social.APActivities

# ActivityPub library config
config :activity_pub, :instance,
  federating: true  # or false, or :manual
```

### Per-User Federation

```elixir
# Enable/disable federation for specific user
Bonfire.Federate.ActivityPub.set_federating(user, true/false)

# Check federation status
Bonfire.Federate.ActivityPub.federating?(user)
```

### Federation Precedence

1. Instance override (if set)
2. User setting (if instance allows)
3. Instance default
4. Manual mode (case-by-case)

## Key Utilities (AdapterUtils)

### Local/Remote Detection

```elixir
is_local?(object, opts \\ [])
  - Checks for Peered association
  - Handles various object structures
  - Supports preloading if needed
```

### Character Resolution

```elixir
get_character(query, opts)
  - By username: @alice or alice
  - By AP ID: https://instance/users/alice
  - By UID: internal pointer ID
```

### Service Actor

Special actor for system activities:
- ID: "1ACT1V1TYPVBREM0TESFETCHER"
- Username: "Federation Bot"
- Used for signed fetches

### Data Conversion

```elixir
# Extract actor IDs from activities
all_actors(activity) → [actor_ids]

# Convert Bonfire objects to AP IDs
id_or_object_id(object) → "https://..."

# Get public/private status
is_public?(activity, object) → boolean
```

## Federation Modules

Modules can declare which activity/object types they handle:

```elixir
defmodule MyModule do
  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  
  def federation_module do
    [
      "Like",                    # Handle all Like activities
      {"Create", "Question"},    # Handle Create Question
      {"Delete", MySchema}       # Handle Delete of specific type
    ]
  end
  
  # Incoming federation
  def ap_receive_activity(character, activity, object) do
    # Process and return {:ok, created_object}
  end
  
  # Outgoing federation
  def ap_publish_activity(subject, verb, object) do
    # Create AP activity and return {:ok, activity}
  end
end
```

### Routing Priority

1. Exact match: `{activity_type, object_type}`
2. Activity type only
3. Object type only
4. Context module (via schemas)
5. Fallback module

## Common Patterns

### Publishing Local Content

```elixir
# In your create function
def create_post(author, attrs) do
  with {:ok, post} <- do_create(author, attrs) do
    # Federate the creation
    Bonfire.Federate.ActivityPub.Outgoing.maybe_federate(
      author,    # subject
      :create,   # verb
      post      # object
    )
    {:ok, post}
  end
end
```

### Receiving Remote Activities

```elixir
defmodule MyContext do
  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  
  def federation_module, do: [{"Create", "MyType"}]
  
  def ap_receive_activity(character, activity, object) do
    attrs = %{
      content: object.data["content"],
      creator: character,
      canonical_uri: object.data["id"]
    }
    
    with {:ok, local_object} <- create_from_remote(attrs) do
      {:ok, local_object}
    end
  end
end
```

### Checking Federation Status

```elixir
# For current user
if Bonfire.Federate.ActivityPub.federating?(current_user) do
  # Show federation features
end

# For content
if Bonfire.Federate.ActivityPub.Outgoing.federate_outgoing?(author) do
  # Allow public addressing
end
```

## Testing Federation

### Manual Testing

```bash
# Test actor endpoint
curl -H "Accept: application/activity+json" \
  "http://localhost:4000/pub/actors/username" | jq '.'

# Test object endpoint  
curl -H "Accept: application/activity+json" \
  "http://localhost:4000/pub/objects/OBJECT_ID" | jq '.'
```

### Testing Strategies

1. **Unit tests** for individual modules
2. **Integration tests** with mock federation
3. **Live testing** between instances
4. **Simulate module** for testing scenarios

### Common Issues

1. **Signatures failing**: Check key generation and storage
2. **Activities not federating**: Check boundaries and federation settings
3. **Remote actors not found**: Check Webfinger and actor fetching
4. **Objects not appearing**: Check activity routing and handlers

## Debugging

### Enable Logging

```elixir
# In config
config :bonfire, log_federation: true
```

### Check Federation Pipeline

1. Is user/instance federating? → `federating?/1`
2. Is content public? → Check boundaries
3. Is activity queued? → Check Oban jobs
4. Is activity delivered? → Check logs
5. Is response processed? → Check incoming pipeline

### Inspect Remote Data

```elixir
# Get remote actor
{:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: "https://...")

# Check Peered mapping
Bonfire.Federate.ActivityPub.Peered.get("https://...")

# Check instance
Bonfire.Federate.ActivityPub.Instances.get_or_create("https://instance.com")
```

## Best Practices

1. **Always check federation settings** before exposing federation features
2. **Respect boundaries** - never bypass boundary checks for federation
3. **Handle remote failures gracefully** - federation is unreliable
4. **Cache appropriately** - remote data should be cached but refreshable
5. **Validate incoming data** - never trust remote content
6. **Log federation events** - helpful for debugging
7. **Test with real implementations** - each platform has quirks
8. **Consider performance** - federation can be resource intensive
9. **Document federation behavior** - users need to understand privacy
10. **Fail safely** - when in doubt, don't federate

## Integration Requirements

To integrate this extension:

1. Add to deps in mix.exs
2. Configure in runtime.exs
3. Ensure boundaries extension is available
4. Implement federation modules for your contexts
5. Add federation UI controls for users
6. Test thoroughly with multiple implementations

## Security Considerations

1. **Always verify HTTP signatures** on incoming requests
2. **Validate actor matches** activity author
3. **Check instance blocks** before processing
4. **Sanitize incoming content** (handled by contexts)
5. **Rate limit** federation endpoints
6. **Monitor** for abuse patterns
7. **Implement** proper error handling
8. **Never expose** private content via federation