# Rules for Working with Bonfire.Federate.ActivityPub

## Core Principles

- **Always respect Bonfire's boundaries** - Never bypass boundary checks for federation
- **Never federate private content** - Check boundaries before any federation operation
- **Always validate remote data** - Remote content must be sanitized and validated
- **Prefer local operations first** - Create locally, then federate (not the reverse)
- **Handle federation failures gracefully** - Remote instances are unreliable
- **Always check federation settings** - Respect instance and user preferences
- **Never trust remote actors** - Verify signatures and validate data
- **Cache appropriately** - Balance performance with freshness
- **Log federation events** - Essential for debugging issues
- **Fail safely** - When in doubt, don't federate

## Architecture Guidelines

### Component Organization

**Always follow the established module structure**:

```elixir
# GOOD - Proper module organization
Bonfire.Federate.ActivityPub.Adapter         # Main adapter callbacks
Bonfire.Federate.ActivityPub.Incoming        # Incoming activity processing
Bonfire.Federate.ActivityPub.Outgoing        # Outgoing federation logic
Bonfire.Federate.ActivityPub.AdapterUtils    # Shared utilities
Bonfire.Federate.ActivityPub.BoundariesMRF   # Boundary filtering
Bonfire.Federate.ActivityPub.Instances       # Instance management

# BAD - Breaking module conventions
Bonfire.ActivityPub.Handler  # Wrong namespace
MyApp.Federation.Adapter     # Custom namespacing
```

### Data Flow Rules

**Always process activities through the proper pipeline**:

```elixir
# GOOD - Following the pipeline
# Incoming: AP → Adapter.handle_activity → Incoming.receive_activity → FederationModule
# Outgoing: Event → Outgoing.maybe_federate → FederationModule → ActivityPub

# BAD - Bypassing the pipeline
# Direct calls to ActivityPub without going through Outgoing
ActivityPub.create(...)  # Should use Outgoing.maybe_federate
```

## Adapter Implementation Rules

### Required Callbacks

**Always implement ALL adapter callbacks completely**:

```elixir
# GOOD - Complete implementation
defmodule Bonfire.Federate.ActivityPub.Adapter do
  @behaviour ActivityPub.Federator.Adapter
  
  @impl true
  def get_actor_by_id(id) do
    case Bonfire.Me.Characters.get(id) do
      {:ok, character} -> {:ok, character_to_actor(character)}
      _ -> {:error, :not_found}
    end
  end
  
  # All other callbacks implemented...
end

# BAD - Partial implementation
defmodule BadAdapter do
  @behaviour ActivityPub.Federator.Adapter
  
  def get_actor_by_id(id), do: {:ok, nil}  # Broken!
  # Missing other required callbacks
end
```

### Actor Retrieval Rules

**Always return properly formatted actors**:

```elixir
# GOOD - Complete actor conversion
def get_actor_by_username(username) do
  with {:ok, character} <- Characters.by_username(username),
       {:ok, actor} <- character_to_actor(character) do
    {:ok, actor}
  else
    _ -> {:error, :not_found}
  end
end

# BAD - Returning raw character
def get_actor_by_username(username) do
  Characters.by_username(username)  # Wrong format!
end
```

### Activity Processing Rules

**Always delegate activity handling to the Incoming module**:

```elixir
# GOOD - Proper delegation
@impl true
def handle_activity(activity) do
  Bonfire.Federate.ActivityPub.Incoming.receive_activity(activity)
end

# BAD - Processing in adapter
@impl true  
def handle_activity(activity) do
  # Don't process activities directly in adapter!
  case activity.data["type"] do
    "Create" -> # ...
  end
end
```

### Federation Control Rules

**Always check boundaries in federate_actor?**:

```elixir
# GOOD - Comprehensive checks
def federate_actor?(actor, direction, opts) do
  by_character = e(opts, :character, nil)
  
  case direction do
    :in ->
      federating?() and
      not instance_blocked?(actor) and
      not actor_blocked?(actor, by_character)
      
    :out ->
      actor.local and
      federating?(by_character) and
      not boundaries_prevent_federation?(actor, by_character)
  end
end

# BAD - No boundary checks
def federate_actor?(_actor, _direction, _opts) do
  true  # Dangerous!
end
```

## Character/Actor Conversion Rules

### Character to Actor Rules

**Always include all required ActivityPub endpoints**:

```elixir
# GOOD - Complete actor structure
def character_to_actor(character) do
  username = e(character, :character, :username, nil)
  
  %ActivityPub.Actor{
    id: character.id,
    data: %{
      "id" => URIs.canonical_url(character),
      "type" => actor_type(character),
      "preferredUsername" => username,
      "name" => e(character, :profile, :name, nil),
      "summary" => e(character, :profile, :summary, nil),
      "inbox" => "#{URIs.canonical_url(character)}/inbox",
      "outbox" => "#{URIs.canonical_url(character)}/outbox",
      "followers" => "#{URIs.canonical_url(character)}/followers",
      "following" => "#{URIs.canonical_url(character)}/following",
      "endpoints" => %{
        "sharedInbox" => "#{URIs.base_url()}/inbox"
      },
      "publicKey" => public_key_map(character)
    },
    local: true,
    keys: e(character, :character, :signing_key, nil),
    pointer_id: character.id,
    username: username,
    ap_id: URIs.canonical_url(character),
    deactivated: false
  }
end

# BAD - Missing required fields
def character_to_actor(character) do
  %ActivityPub.Actor{
    id: character.id,
    data: %{"id" => some_url(character)},
    local: true
  }
end
```

### Actor Type Mapping

**Always map Bonfire character types correctly**:

```elixir
# GOOD - Proper type mapping
def actor_type(character) do
  case Types.object_type(character) do
    Bonfire.Data.Identity.User -> "Person"
    Bonfire.Classify.Category -> "Group"  
    _ -> "Person"  # Safe default
  end
end

# BAD - Always using Person
def actor_type(_character) do
  "Person"  # Groups won't work properly!
end
```

### Key Management Rules

**Always ensure actors have signing keys**:

```elixir
# GOOD - Key generation when needed
def ensure_character_keys(character) do
  if e(character, :character, :signing_key, nil) do
    {:ok, character}
  else
    {:ok, keys} = Bonfire.Me.Characters.generate_signing_key(character)
    {:ok, character}
  end
end

# BAD - Creating actor without keys
def character_to_actor(character) do
  %ActivityPub.Actor{
    # ...
    keys: nil,  # Federation will fail!
    # ...
  }
end
```

## Incoming Federation Rules

### Activity Routing Rules

**Always route activities through FederationModules**:

```elixir
# GOOD - Proper routing
def receive_activity(activity) do
  with {:ok, actor} <- get_actor(activity),
       {:ok, character} <- get_character(actor),
       {:ok, object} <- get_object(activity),
       module when not is_nil(module) <- find_handler_module(activity, object) do
    module.ap_receive_activity(character, activity, object)
  else
    nil -> 
      # Fallback for unknown activity types
      handle_unknown_activity(activity)
    error ->
      error
  end
end

# BAD - Hardcoded activity handling
def receive_activity(%{data: %{"type" => "Create"}}) do
  # Don't hardcode handlers!
  Bonfire.Social.Posts.create_from_ap(...)
end
```

### Object Creation Rules

**Always generate proper pointer IDs for remote objects**:

```elixir
# GOOD - Deterministic pointer ID
def pointer_id_for_object(object) do
  # Use published date for deterministic IDs
  published = e(object, :data, "published", nil) || DateTime.utc_now()
  Bonfire.Common.Pointers.id_generator(published)
end

# BAD - Random IDs for remote objects
def pointer_id_for_object(_object) do
  Ecto.UUID.generate()  # Not deterministic!
end
```

### Peered Mapping Rules

**Always save canonical URI mappings**:

```elixir
# GOOD - Save peered relationship
def process_remote_object(object, pointer_id) do
  with {:ok, peer} <- get_or_create_peer(object),
       {:ok, _peered} <- create_peered(pointer_id, peer, object.data["id"]) do
    {:ok, object}
  end
end

# BAD - No peered mapping
def process_remote_object(object, pointer_id) do
  # Missing peered relationship!
  {:ok, object}
end
```

### Handler Module Rules

**Always implement ap_receive_activity/3 in handler modules**:

```elixir
# GOOD - Proper handler implementation
defmodule Bonfire.Social.Posts do
  def ap_receive_activity(character, activity, %{data: %{"type" => "Note"}} = object) do
    with {:ok, post} <- create_from_ap(character, object),
         {:ok, _} <- maybe_notify(character, post) do
      {:ok, post}
    end
  end
end

# BAD - Wrong signature
defmodule BadHandler do
  def ap_receive_activity(activity) do  # Missing parameters!
    # ...
  end
end
```

## Outgoing Federation Rules

### Federation Decision Rules

**Always check if content should federate before publishing**:

```elixir
# GOOD - Complete federation checks
def maybe_federate(subject, verb, object, opts) do
  cond do
    not federating?() ->
      debug("Federation disabled globally")
      :ok
      
    not is_local?(subject) ->
      debug("Subject is not local")
      :ok
      
    boundaries_prevent?(subject, object) ->
      debug("Boundaries prevent federation")
      :ok
      
    true ->
      prepare_and_queue(subject, verb, object, opts)
  end
end

# BAD - No checks
def maybe_federate(subject, verb, object, opts) do
  prepare_and_queue(subject, verb, object, opts)  # Always federates!
end
```

### Activity Publishing Rules

**Always use the correct ActivityPub verb**:

```elixir
# GOOD - Proper verb mapping
def publish_activity(subject, verb, object) do
  case verb do
    :create -> ActivityPub.create(...)
    :update -> ActivityPub.update(...) 
    :delete -> ActivityPub.delete(...)
    :follow -> ActivityPub.follow(...)
    :like -> ActivityPub.like(...)
    :boost -> ActivityPub.announce(...)
    :flag -> ActivityPub.flag(...)
  end
end

# BAD - Wrong verb usage
def publish_activity(subject, :boost, object) do
  ActivityPub.like(...)  # Wrong verb!
end
```

### Boundary Checking Rules

**Never federate content that boundaries restrict**:

```elixir
# GOOD - Check boundaries before federation
def should_federate?(author, object) do
  with {:ok, opts} <- Bonfire.Boundaries.query_agents_read(object) do
    # Check if public or federated audience
    :public in opts or :federated in opts
  else
    _ -> false
  end
end

# BAD - Ignoring boundaries
def should_federate?(_author, _object) do
  true  # Privacy violation!
end
```

### Special Case Rules

**Always handle user deletion properly**:

```elixir
# GOOD - Proper deletion handling
def maybe_federate(subject, :delete, %Bonfire.Data.Identity.User{} = user, _opts) do
  if subject.id == user.id do
    # User deleting themselves - federate actor deletion
    ActivityPub.Actor.delete(character_to_actor(user))
  else
    {:error, :unauthorized}
  end
end

# BAD - No authorization check
def maybe_federate(_subject, :delete, user, _opts) do
  ActivityPub.Actor.delete(character_to_actor(user))  # Anyone can delete!
end
```

## Boundaries Integration Rules

### BoundariesMRF Implementation

**Always respect Bonfire's block types in MRF**:

```elixir
# GOOD - Proper block type handling
def filter(activity, is_local?) do
  with {:ok, activity} <- check_ghost_blocks(activity, is_local?),
       {:ok, activity} <- check_silence_blocks(activity, is_local?),
       {:ok, activity} <- check_regular_blocks(activity, is_local?) do
    {:ok, activity}
  else
    {:reject, reason} -> {:reject, reason}
    :ignore -> :ignore
  end
end

# BAD - Ignoring block types
def filter(activity, _is_local?) do
  {:ok, activity}  # No filtering!
end
```

### Ghost Block Rules

**Always filter ghosted recipients from outgoing activities**:

```elixir
# GOOD - Ghost filtering for outgoing
def filter_ghosted_recipients(activity, local_author_ids) do
  filtered = activity
  |> Map.update(:to, [], &filter_ghosted(&1, local_author_ids))
  |> Map.update(:cc, [], &filter_ghosted(&1, local_author_ids))
  
  if Enum.empty?(filtered.to) and Enum.empty?(filtered.cc) do
    :ignore  # No recipients left
  else
    {:ok, filtered}
  end
end

# BAD - Not filtering ghosted recipients  
def filter_ghosted_recipients(activity, _) do
  {:ok, activity}  # Ghosted users will receive!
end
```

### Silence Block Rules

**Never allow follows to silenced actors from local users**:

```elixir
# GOOD - Block follows to silenced actors
def check_silence_blocks(%{data: %{"type" => "Follow"}} = activity, true = _is_local) do
  object_actor = get_object_actor(activity)
  
  if actor_silenced?(object_actor) do
    {:reject, "Cannot follow silenced actor"}
  else
    {:ok, activity}
  end
end

# BAD - Allowing follows to silenced actors
def check_silence_blocks(activity, _) do
  {:ok, activity}  # Bypasses silence!
end
```

### Instance Block Rules

**Always check both config and database for instance blocks**:

```elixir
# GOOD - Complete instance blocking
def instance_blocked?(uri) do
  host = URI.parse(uri).host
  
  # Check config regex
  config_blocked?(host) or
  # Check database blocks
  Bonfire.Federate.ActivityPub.Instances.instance_blocked?(host)
end

# BAD - Only checking config
def instance_blocked?(uri) do
  config_blocked?(URI.parse(uri).host)  # Misses DB blocks!
end
```

### Recipient Filtering Rules

**Always filter all addressing fields**:

```elixir
# GOOD - Filter all recipient fields
def filter_recipients(activity, block_types, is_local?) do
  activity
  |> filter_field(:to, block_types, is_local?)
  |> filter_field(:cc, block_types, is_local?)
  |> filter_field(:bto, block_types, is_local?)
  |> filter_field(:bcc, block_types, is_local?)
  |> filter_field(:audience, block_types, is_local?)
end

# BAD - Missing recipient fields
def filter_recipients(activity, block_types, _) do
  activity
  |> filter_field(:to, block_types)  # Missing cc, bto, etc!
end
```

## Instance & Peer Management Rules

### Peer Creation Rules

**Always normalize instance URLs when creating peers**:

```elixir
# GOOD - Normalized peer creation
def get_or_create_peer(uri) when is_binary(uri) do
  parsed = URI.parse(uri)
  host = parsed.host
  base_url = "#{parsed.scheme}://#{host}"
  
  Bonfire.Federate.ActivityPub.Peers.get_or_create(
    host: host,
    base_url: base_url,
    display_hostname: host
  )
end

# BAD - Inconsistent peer data
def get_or_create_peer(uri) do
  Bonfire.Federate.ActivityPub.Peers.get_or_create(
    host: uri  # Not normalized!
  )
end
```

### Peered Relationship Rules

**Always create peered relationships for remote objects**:

```elixir
# GOOD - Complete peered setup
def save_peered_object(object_id, canonical_uri) do
  with {:ok, peer} <- get_or_create_peer(canonical_uri),
       {:ok, peered} <- Bonfire.Federate.ActivityPub.Peered.save(object_id, peer, canonical_uri),
       {:ok, _} <- add_to_instance_circle(object_id, peer) do
    {:ok, peered}
  end
end

# BAD - Missing peered relationship
def save_peered_object(object_id, _canonical_uri) do
  {:ok, object_id}  # No tracking of remote origin!
end
```

### Instance Circle Rules

**Always add remote actors to instance circles**:

```elixir
# GOOD - Proper circle management
def add_to_instance_circle(character, peer) do
  with {:ok, circle} <- get_or_create_instance_circle(peer) do
    Bonfire.Social.Circles.add_to_circle(character, circle)
  end
end

# BAD - No circle tracking
def process_remote_actor(actor) do
  # Missing instance circle addition
  {:ok, actor}
end
```

### Instance Blocking Rules

**Always check instance blocks at multiple levels**:

```elixir
# GOOD - Multi-level instance blocking
def check_instance_blocks(uri, user) do
  host = URI.parse(uri).host
  
  # Check in order of precedence
  cond do
    instance_blocked_globally?(host) -> {:blocked, :global}
    instance_blocked_by_user?(host, user) -> {:blocked, :user}
    true -> :ok
  end
end

# BAD - Single level check
def check_instance_blocks(uri, _user) do
  if instance_blocked_globally?(uri) do
    :blocked
  else
    :ok  # Missing user-level blocks!
  end
end
```

## Configuration Rules

### Instance Configuration Rules

**Always set clear federation defaults**:

```elixir
# GOOD - Explicit configuration
config :activity_pub, :instance,
  federating: true  # Clear default
  
config :bonfire,
  log_federation: true,
  federation_fallback_module: Bonfire.Social.APActivities

# BAD - Ambiguous configuration
# No explicit federation setting - unclear behavior
```

**Never change federation adapter at runtime**:

```elixir
# WRONG - Runtime adapter change
Application.put_env(:activity_pub, :adapter, NewAdapter)

# CORRECT - Set in config files only
config :activity_pub, :adapter, Bonfire.Federate.ActivityPub.Adapter
```

### Per-User Federation Rules

**Always respect federation precedence**:

```elixir
# GOOD - Proper precedence checking
def federating?(user) do
  cond do
    # Instance override takes precedence
    instance_override = Config.get(:federation_override) -> 
      instance_override
      
    # User setting if instance allows
    instance_allows_user_choice?() ->
      get_user_federation_setting(user)
      
    # Fall back to instance default
    true ->
      Config.get([:activity_pub, :instance, :federating], true)
  end
end

# BAD - Ignoring precedence
def federating?(user) do
  get_user_federation_setting(user)  # Ignores instance override!
end
```

### Federation Mode Rules

**Always handle manual mode correctly**:

```elixir
# GOOD - Manual mode handling
def should_federate?(object) when federating() == :manual do
  # Check explicit federation flag on object
  e(object, :federate, false)
end

def should_federate?(_object) when federating() == false do
  false
end

def should_federate?(_object) when federating() == true do
  true
end

# BAD - Not handling manual mode
def should_federate?(_object) do
  federating()  # Binary when it could be :manual!
end
```

## Utility Function Rules (AdapterUtils)

### Local/Remote Detection Rules

**Always check peered association for remote detection**:

```elixir
# GOOD - Comprehensive local check
def is_local?(object, opts \\ []) do
  cond do
    # Has peered? It's remote
    has_peered_assoc?(object, opts) -> false
    
    # Has local character association
    has_character_assoc?(object) -> true
    
    # Check by URL pattern
    is_binary(object) -> String.starts_with?(object, base_url())
    
    # Default to local
    true -> true
  end
end

# BAD - Incomplete check
def is_local?(object, _opts) do
  # Only checking URL pattern
  String.starts_with?(object, base_url())
end
```

### Character Resolution Rules

**Always handle all character query formats**:

```elixir
# GOOD - Complete character resolution
def get_character(query, opts) do
  cond do
    # Username with @
    String.starts_with?(query, "@") ->
      Characters.by_username(String.slice(query, 1..-1))
      
    # ActivityPub ID
    String.starts_with?(query, "http") ->
      get_character_by_ap_id(query)
      
    # Pointer ID
    is_binary(query) and byte_size(query) == 26 ->
      Characters.get(query)
      
    # Plain username
    is_binary(query) ->
      Characters.by_username(query)
  end
end

# BAD - Limited query support
def get_character(username, _opts) do
  Characters.by_username(username)  # Only handles usernames!
end
```

### Service Actor Rules

**Always use the service actor for system activities**:

```elixir
# GOOD - Proper service actor usage
def fetch_with_signature(url) do
  service_actor = get_service_actor()
  
  ActivityPub.HTTP.get(url,
    signing_actor: service_actor,
    date: DateTime.utc_now()
  )
end

# BAD - No signature for system fetches
def fetch_with_signature(url) do
  HTTPoison.get(url)  # Unsigned!
end
```

**Never expose service actor publicly**:

```elixir
# GOOD - Service actor not in public listings
def list_local_actors do
  Characters.list_local()
  |> Enum.reject(&is_service_actor?/1)
end

# BAD - Service actor visible
def list_local_actors do
  Characters.list_local()  # Includes service actor!
end
```

### Data Extraction Rules

**Always handle nested actor references**:

```elixir
# GOOD - Extract all actor references
def all_actors(activity) do
  [
    e(activity, :data, "actor", nil),
    e(activity, :data, "object", "attributedTo", nil),
    e(activity, :data, "object", "actor", nil)
  ]
  |> Enum.reject(&is_nil/1)
  |> Enum.uniq()
end

# BAD - Missing actor references
def all_actors(activity) do
  [activity.data["actor"]]  # Misses attributedTo!
end
```

## Federation Module Rules

### Module Declaration Rules

**Always declare federation patterns explicitly**:

```elixir
# GOOD - Clear pattern declaration
defmodule Bonfire.Social.Posts do
  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  
  def federation_module do
    [
      {"Create", "Note"},      # Create Note activities
      {"Create", "Article"},   # Create Article activities
      {"Update", "Note"},      # Update Note activities
      {"Update", "Article"},   # Update Article activities
      {"Delete", Bonfire.Data.Social.Post}  # Delete with schema
    ]
  end
end

# BAD - Ambiguous patterns
defmodule BadModule do
  def federation_module do
    ["Create"]  # Too broad - will catch all Creates!
  end
end
```

### Handler Implementation Rules

**Always implement both receive and publish callbacks**:

```elixir
# GOOD - Complete implementation
defmodule Bonfire.Social.Likes do
  @behaviour Bonfire.Federate.ActivityPub.FederationModules
  
  def ap_receive_activity(character, activity, object) do
    with {:ok, liked} <- get_local_object(object),
         {:ok, like} <- create_like(character, liked) do
      {:ok, like}
    end
  end
  
  def ap_publish_activity(subject, :like, object) do
    with {:ok, actor} <- character_to_actor(subject),
         {:ok, ap_object} <- object_to_ap(object),
         {:ok, activity} <- ActivityPub.like(actor, ap_object) do
      {:ok, activity}
    end
  end
end

# BAD - Missing callback
defmodule BadModule do
  def ap_receive_activity(_, _, _), do: {:ok, nil}
  # Missing ap_publish_activity!
end
```

### Routing Priority Rules

**Always understand routing precedence**:

```elixir
# Routing precedence (first match wins):
# 1. Exact match: {"Create", "Note"}
# 2. Activity only: "Create"
# 3. Object type: "Note"
# 4. Schema match: Bonfire.Data.Social.Post
# 5. Fallback module

# GOOD - Specific patterns first
def federation_module do
  [
    {"Create", "Question"},  # Specific first
    {"Create", "Note"},      # Then general Note
    "Create"                  # Catch-all last
  ]
end

# BAD - Catch-all first
def federation_module do
  [
    "Create",                 # Catches everything!
    {"Create", "Question"}   # Never reached
  ]
end
```

### Error Handling Rules

**Always return proper error tuples from handlers**:

```elixir
# GOOD - Proper error handling
def ap_receive_activity(character, activity, object) do
  case create_from_activity(character, object) do
    {:ok, created} -> {:ok, created}
    {:error, :not_found} -> {:error, "Referenced object not found"}
    {:error, changeset} -> {:error, format_errors(changeset)}
    _ -> {:error, "Unknown error processing activity"}
  end
end

# BAD - Silent failures
def ap_receive_activity(character, activity, object) do
  create_from_activity(character, object)
  {:ok, nil}  # Always returns success!
end
```

## Common Implementation Patterns

### Publishing Local Content

**Always federate after successful local operations**:

```elixir
# GOOD - Create locally, then federate
def create_post(author, attrs) do
  with {:ok, post} <- do_create(author, attrs),
       {:ok, _} <- maybe_index(post),
       :ok <- Bonfire.Federate.ActivityPub.Outgoing.maybe_federate(
         author,
         :create,
         post
       ) do
    {:ok, post}
  else
    error ->
      # Post created but not federated - that's ok
      error
  end
end

# BAD - Federation blocks local creation
def create_post(author, attrs) do
  with :ok <- check_can_federate(author),  # Unnecessary check
       {:ok, post} <- do_create(author, attrs),
       {:ok, _} <- federate_or_fail(author, post) do  # Fails whole operation
    {:ok, post}
  end
end
```

### Receiving Remote Activities

**Always validate and normalize remote data**:

```elixir
# GOOD - Proper remote data handling
def ap_receive_activity(character, activity, object) do
  with {:ok, attrs} <- extract_attributes(object),
       {:ok, normalized} <- normalize_content(attrs),
       {:ok, local_object} <- create_from_remote(character, normalized),
       {:ok, _} <- save_peered_relationship(local_object, object) do
    {:ok, local_object}
  end
end

defp extract_attributes(object) do
  {:ok, %{
    content: e(object, :data, "content", ""),
    summary: e(object, :data, "summary", nil),
    published_at: parse_published_date(object),
    canonical_uri: e(object, :data, "id", nil)
  }}
end

# BAD - Direct attribute usage
def ap_receive_activity(character, _activity, object) do
  create_from_remote(character, object.data)  # Unvalidated data!
end
```

### Federation Status Checks

**Always check federation at appropriate levels**:

```elixir
# GOOD - Context-aware federation checks
def show_federation_ui?(current_user, object) do
  # User can federate
  Bonfire.Federate.ActivityPub.federating?(current_user) and
  # Object can be federated
  can_federate_object?(object) and
  # User has permission
  can?(current_user, :federate, object)
end

# BAD - Only checking global setting
def show_federation_ui?(_user, _object) do
  Config.get([:activity_pub, :instance, :federating])
end
```

### Error Recovery Patterns

**Always handle federation failures gracefully**:

```elixir
# GOOD - Graceful degradation
def handle_incoming_like(character, activity, object) do
  case get_local_object(object) do
    {:ok, local} ->
      create_like(character, local)
      
    {:error, :not_found} ->
      # Try to fetch the object
      case fetch_and_store_object(object) do
        {:ok, fetched} -> create_like(character, fetched)
        _ -> {:error, "Cannot find object to like"}
      end
  end
end

# BAD - Immediate failure
def handle_incoming_like(character, _activity, object) do
  {:ok, local} = get_local_object(object)  # Crashes if not found
  create_like(character, local)
end
```

## Testing Federation Rules

### Manual Testing Rules

**Always test with proper Accept headers**:

```bash
# GOOD - Proper ActivityPub testing
curl -H "Accept: application/activity+json" \
     -H "Date: $(date -u +'%a, %d %b %Y %H:%M:%S GMT')" \
     "http://localhost:4000/pub/actors/username" | jq '.'

# BAD - Missing Accept header
curl "http://localhost:4000/pub/actors/username"  # Returns HTML!
```

**Always verify response format**:

```bash
# GOOD - Validate ActivityStreams format
curl -H "Accept: application/activity+json" "$URL" | \
  jq 'if .type and .id then "Valid AS2" else "Invalid" end'

# BAD - No validation
curl -H "Accept: application/activity+json" "$URL"
```

### Test Implementation Rules

**Always use test-specific federation modules**:

```elixir
# GOOD - Test isolation
defmodule Bonfire.Federate.ActivityPub.Test.MockFederation do
  use Bonfire.Federate.ActivityPub.FederationModules
  
  def federation_module, do: [{"Test", "Mock"}]
  
  def ap_receive_activity(_, _, _), do: {:ok, %{id: "test"}}
  def ap_publish_activity(_, _, _), do: {:ok, %{id: "test"}}
end

# BAD - Using production modules in tests
# Tests become dependent on real implementation details
```

### Integration Test Rules

**Always mock external HTTP calls**:

```elixir
# GOOD - Predictable test behavior
setup do
  Tesla.Mock.mock(fn
    %{method: :get, url: "https://remote.test/.well-known/webfinger" <> _} ->
      %Tesla.Env{status: 200, body: webfinger_response()}
      
    %{method: :post, url: "https://remote.test/inbox"} ->
      %Tesla.Env{status: 202, body: ""}
  end)
end

# BAD - Real network calls in tests
# Tests fail when network is down or remote changes
```

### Common Issue Detection Rules

**Always check signatures in tests**:

```elixir
# GOOD - Verify signature presence
test "outgoing requests are signed" do
  Tesla.Mock.mock(fn env ->
    assert env.headers["signature"]
    assert env.headers["date"]
    %Tesla.Env{status: 200}
  end)
  
  # Trigger federation...
end

# BAD - Not verifying signatures
test "federation works" do
  # Test passes even if signatures are broken
end
```

## Debugging Federation Rules

### Logging Configuration Rules

**Always enable federation logging when debugging**:

```elixir
# GOOD - Comprehensive logging
config :bonfire, 
  log_federation: true,
  log_federation_verbose: true
  
config :logger, :console,
  level: :debug,
  metadata: [:module, :actor_id, :activity_id, :peer_id]

# BAD - Insufficient logging
config :bonfire, log_federation: false
```

### Pipeline Debugging Rules

**Always check the complete federation pipeline**:

```elixir
# GOOD - Systematic pipeline check
def debug_federation_issue(object) do
  IO.puts "=== Federation Debug ==="
  
  # 1. Check global federation
  IO.puts "Federating globally? #{federating?()}"
  
  # 2. Check user federation
  author = get_author(object)
  IO.puts "User federating? #{federating?(author)}"
  
  # 3. Check boundaries
  IO.puts "Boundaries allow? #{boundaries_allow_federation?(object)}"
  
  # 4. Check job queue
  jobs = get_federation_jobs(object)
  IO.puts "Jobs queued: #{length(jobs)}"
  
  # 5. Check delivery
  deliveries = get_delivery_attempts(object)
  IO.puts "Delivery attempts: #{length(deliveries)}"
end

# BAD - Incomplete debugging
def debug_federation_issue(object) do
  IO.puts federating?()  # Only checks one thing!
end
```

### Remote Data Inspection Rules

**Always handle inspection errors gracefully**:

```elixir
# GOOD - Safe inspection
def inspect_remote_actor(ap_id) do
  case ActivityPub.Actor.get_cached(ap_id: ap_id) do
    {:ok, actor} ->
      IO.inspect(actor, label: "Cached actor")
      
    _ ->
      IO.puts("Not in cache, fetching...")
      case ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id) do
        {:ok, actor} -> IO.inspect(actor, label: "Fetched actor")
        {:error, e} -> IO.puts("Fetch failed: #{inspect(e)}")
      end
  end
end

# BAD - Unsafe inspection
def inspect_remote_actor(ap_id) do
  {:ok, actor} = ActivityPub.Actor.get_cached_or_fetch(ap_id: ap_id)
  IO.inspect(actor)  # Crashes on error!
end
```

### Job Queue Inspection Rules

**Always filter federation jobs specifically**:

```elixir
# GOOD - Targeted job inspection
def inspect_federation_jobs do
  import Ecto.Query
  
  Oban.Job
  |> where([j], j.queue in ["federation", "federator_outgoing", "federator_incoming"])
  |> where([j], j.state in ["available", "executing", "retryable", "scheduled"])
  |> order_by([j], desc: j.inserted_at)
  |> limit(20)
  |> Repo.all()
  |> Enum.map(fn job ->
    %{
      id: job.id,
      queue: job.queue,
      state: job.state,
      worker: job.worker,
      attempt: job.attempt,
      errors: job.errors,
      scheduled_at: job.scheduled_at
    }
  end)
end

# BAD - Too much data
def inspect_federation_jobs do
  Oban.Job |> Repo.all()  # Returns thousands of jobs!
end
```

## Best Practices Summary

### Core Federation Rules
- **Always check federation settings** at instance and user level
- **Never bypass boundaries** for federation operations
- **Always validate remote data** before processing
- **Never trust remote content** without sanitization

### Performance Rules
- **Always cache remote data** with appropriate TTLs
- **Always use background jobs** for federation operations
- **Never block on remote operations** in request cycle
- **Always batch deliveries** to same instance

### Security Rules  
- **Always verify HTTP signatures** on incoming requests
- **Always validate actor matches** activity author
- **Always check instance blocks** before processing
- **Never expose private content** via federation

### Error Handling Rules
- **Always handle remote failures gracefully**
- **Always implement timeouts** for remote operations
- **Always log federation events** for debugging
- **Always fail safely** - when in doubt, don't federate

### Testing Rules
- **Always test with real implementations** - each has quirks
- **Always mock external calls** in unit tests
- **Always verify signatures** in integration tests
- **Always test boundary enforcement**

## Integration Checklist

**Required steps to integrate this extension**:

1. ✓ Add `bonfire_federate_activitypub` to deps in mix.exs
2. ✓ Configure adapter in runtime.exs:
   ```elixir
   config :activity_pub, :adapter, Bonfire.Federate.ActivityPub.Adapter
   ```
3. ✓ Ensure boundaries extension is available and configured
4. ✓ Implement federation modules for your contexts
5. ✓ Add federation UI controls for users
6. ✓ Set up instance actor and keys
7. ✓ Configure MRF policies if needed
8. ✓ Test with major implementations (Mastodon, Pleroma, etc)

## Security Checklist

**Security requirements for production**:

1. ✓ HTTP signatures verified on all incoming requests
2. ✓ Actor validation ensures author matches activity
3. ✓ Instance blocking checked at multiple levels
4. ✓ Content sanitization implemented in contexts
5. ✓ Rate limiting configured for federation endpoints
6. ✓ Monitoring setup for abuse patterns
7. ✓ Error handling prevents information leaks
8. ✓ Private content never exposed to federation