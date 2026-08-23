# dev/test-only interop probe: not compiled into prod releases at all, so it needs no runtime guards
if Application.compile_env(:bonfire, :env) in [:test, :dev] do
  defmodule Bonfire.Federate.ActivityPub.Testing.Interop do
    @moduledoc """
    Dev/test toolkit for probing federation interop against REAL remote instances, and recording what happens as fixtures.

    Built for the group-federation interop passes (see the public group federation plan), but nothing here is group-specific, it can work for any remote actor.

    Anything that can assert on its own belongs in a `live_federation` test calling these helpers (see `group_interop_live_test.exs`), use IEx for the steps that need a human on the remote side, or for exploration.

    ## Usage

    Run a tunnelled dev instance so remotes can fetch back and verify our signatures:

        just dev-federate-tunnel
        # then in the IEx session:

        alias Bonfire.Federate.ActivityPub.Testing.Interop, as: I

        me = I.local_user("myusername")
        {:ok, community} = I.fetch("!technology@lemmy.world")
        I.follow("!technology@lemmy.world", as: me)
        # ... wait for their fan-out to arrive ...
        I.incoming(from: "lemmy.world")
        I.save_fixture(community.data, "lemmy/group_actor.json")

    Or run a whole scripted flow and get a report:

        I.Groups.group_flow("!lemmyworldtest@lemmy.world", as: me, wait: 120)

    ## What is real vs what needs the capture hooks

    `incoming/1` reads the `ap_object` table, so it sees activities we successfully INGESTED — it cannot show payloads we rejected or failed to parse, and stored data is post-normalisation. For verbatim wire capture (including rejects) the `AP_CAPTURE_INBOX`/`AP_CAPTURE_OUTBOX` hooks in the activity_pub lib are needed.
    """

    use Bonfire.Common.Utils
    use Bonfire.Common.Repo
    import Ecto.Query
    import Untangle

    alias Bonfire.Federate.ActivityPub.AdapterUtils
    alias ActivityPub.Actor
    alias ActivityPub.Object

    @fixtures_path "forks/activity_pub/test/fixtures"

    @doc "Looks up a local user to act as (by username), so probes can be run as a real actor."
    def local_user(username) when is_binary(username) do
      case Bonfire.Me.Users.by_username(username) do
        {:ok, user} -> repo().maybe_preload(user, [:character, :peered])
        other -> error(other, "No local user found for #{username}")
      end
    end

    # ------------------------------------------------------------------
    # resolving & fetching remote actors
    # ------------------------------------------------------------------

    @doc """
    Resolves and fetches a remote actor, accepting any of the group-reference syntaxes in the wild: `!group@host` (threadiverse), `@group@host` / `group@host` (microblog), `&group@host` (Bonfire), or a plain URI.

    Returns the `ActivityPub.Actor` (its `.data` is the wire JSON, ready to `save_fixture/2`).
    """
    def fetch(handle_or_uri, opts \\ []) when is_binary(handle_or_uri) do
      # the binary clause auto-routes: URIs are fetched directly, `name@host` goes via WebFinger
      query = normalise_handle(handle_or_uri)

      case Actor.get_cached_or_fetch(query, opts) do
        {:ok, actor} ->
          summarise_actor(actor)
          maybe_save(actor.data, opts)
          {:ok, actor}

        other ->
          error(
            other,
            "Could not resolve #{query} — check the handle/URI, and that this instance can reach that host (webfinger + signed fetch)"
          )
      end
    end

    @doc "Strips any of the `!`/`@`/`&`/`+` group-reference prefixes, leaving a URI or `name@host`."
    def normalise_handle("!" <> rest), do: normalise_handle(rest)
    def normalise_handle("&" <> rest), do: normalise_handle(rest)
    def normalise_handle("+" <> rest), do: normalise_handle(rest)
    def normalise_handle("@" <> rest), do: normalise_handle(rest)
    def normalise_handle(other), do: other

    defp summarise_actor(actor) do
      data = e(actor, :data, %{})

      IO.puts("""

      ── remote actor ────────────────────────────────
        id:          #{e(actor, :ap_id, nil)}
        type:        #{data["type"]}
        username:    #{e(actor, :username, nil)}
        inbox:       #{data["inbox"]}
        sharedInbox: #{e(data, "endpoints", "sharedInbox", nil)}
        followers:   #{data["followers"]}
        attributedTo (mods?): #{inspect(data["attributedTo"])}
        postingRestrictedToMods: #{inspect(data["postingRestrictedToMods"])}
        featured:    #{inspect(data["featured"])}
      ────────────────────────────────────────────────
      """)
    end

    # ------------------------------------------------------------------
    # interacting
    # ------------------------------------------------------------------

    @doc """
    Follows a remote actor as a local user: `follow("!technology@lemmy.world", as: me)`.

    For group actors this is also the join flow — watch for their `Accept` (and any subsequent fan-out) with `await_incoming/2`.
    """
    def follow(handle_or_uri, opts) when is_binary(handle_or_uri) do
      follower = as_user!(opts)

      with {:ok, actor} <- fetch(handle_or_uri, opts),
           {:ok, followed} <- AdapterUtils.return_pointable(actor, skip_boundary_check: true) do
        Bonfire.Social.Graph.Follows.follow(follower, followed, opts)
        |> tap(fn result -> IO.inspect(result, label: "follow result") end)
      end
    end

    @doc """
    Publishes a post from a local user addressed to a remote actor (eg. a group), so we can observe what the remote does with it.

    Delivers for real — point it at a remote you control (or a second dev instance) unless you mean to post publicly. Prints the prepared outgoing JSON.
    """
    def post_to(handle_or_uri, html_body, opts \\ []) when is_binary(handle_or_uri) do
      author = as_user!(opts)

      with {:ok, actor} <- fetch(handle_or_uri, opts),
           {:ok, target} <- AdapterUtils.return_pointable(actor, skip_boundary_check: true),
           {:ok, post} <-
             Bonfire.Posts.publish(
               current_user: author,
               post_attrs: %{
                 post_content: %{
                   html_body: html_body,
                   name: opts[:title]
                 }
               },
               to_circles: [uid(target)],
               to_boundaries: opts[:boundary] || "public"
             ) do
        IO.puts("published #{uid(post)} — outgoing JSON:")
        IO.inspect(outgoing_json(post), limit: :infinity, printable_limit: :infinity)
        {:ok, post}
      end
    end

    @doc "Returns the AP JSON we prepared for a local object or activity (nil until federation has prepared it)."
    def outgoing_json(thing) do
      case Object.get_cached(pointer: uid(thing)) do
        {:ok, %{data: data}} -> data
        _ -> nil
      end
    end

    # ------------------------------------------------------------------
    # observing what arrived
    # ------------------------------------------------------------------

    @doc """
    Lists recently INGESTED remote activities, newest first — `incoming(from: "lemmy.world", limit: 20)`.

    Only shows what we successfully stored; use the `AP_CAPTURE_INBOX` hook to also see payloads we rejected.
    """
    def incoming(opts \\ []) do
      limit = opts[:limit] || 20

      from(o in Object, where: o.local == false, order_by: [desc: o.id], limit: ^limit)
      |> maybe_filter_host(opts[:from])
      |> repo().all()
      |> tap(&print_incoming/1)
    end

    @doc """
    Polls until an INGESTED incoming activity matches, or the timeout passes. Returns the `ActivityPub.Object` or nil.

    Filters: `type:` (eg. "Accept"), `from:` (actor ap_id), `about:` (an ap_id the activity's object references, at any nesting). Opts: `seconds:` (default 90), `every:` ms between polls.

        Interop.await_incoming(type: "Accept", from: group.ap_id)
        Interop.await_incoming([type: "Announce", from: group.ap_id, about: post_ap_id], seconds: 180)
    """
    def await_incoming(filters, opts \\ []) do
      deadline = System.monotonic_time(:second) + (opts[:seconds] || 90)
      do_await(filters, deadline, opts[:every] || 3_000)
    end

    defp do_await(filters, deadline, every) do
      found =
        from(o in Object, where: o.local == false, order_by: [desc: o.id], limit: 100)
        |> repo().all()
        |> Enum.find(&matches?(&1.data, filters))

      cond do
        found ->
          found

        System.monotonic_time(:second) >= deadline ->
          nil

        true ->
          Process.sleep(every)
          do_await(filters, deadline, every)
      end
    end

    defp matches?(data, filters) do
      Enum.all?(filters, fn
        {:type, type} -> data["type"] == type
        {:from, actor} -> Object.get_ap_id(data["actor"]) == actor
        {:about, ap_id} -> references?(data["object"], ap_id)
        _ -> true
      end)
    end

    @doc "Whether an activity object references `ap_id` — as a bare id, an embedded object, or a wrapped activity (1b12 `Announce{Create{…}}`)."
    def references?(object, ap_id) do
      Object.get_ap_id(object) == ap_id or
        (is_map(object) and references?(object["object"], ap_id))
    end

    defp maybe_filter_host(query, host) when is_binary(host),
      do: where(query, [o], fragment("?->>'actor' ILIKE ?", o.data, ^"%#{host}%"))

    defp maybe_filter_host(query, _), do: query

    defp print_incoming(objects) do
      IO.puts("\n── incoming (#{length(objects)}) ──────────────────")

      for %{data: data} <- objects do
        inner = data["object"]

        inner_desc =
          cond do
            is_binary(inner) -> "object: <id> #{inner}"
            is_map(inner) -> "object: #{inner["type"]} #{inner["id"]}"
            true -> "object: —"
          end

        IO.puts(
          "  #{data["type"]} by #{data["actor"]}\n    #{inner_desc}\n    audience: #{inspect(data["audience"])} to: #{inspect(data["to"])} cc: #{inspect(data["cc"])}"
        )
      end

      IO.puts("──────────────────────────────────────────────\n")
    end

    # ------------------------------------------------------------------
    # recording fixtures
    # ------------------------------------------------------------------

    @doc "Saves any map as a pretty-printed fixture, eg. `save_fixture(actor.data, \"lemmy/group_actor.json\")`."
    def save_fixture(data, relative_path) when is_map(data) do
      path = Path.join(@fixtures_path, relative_path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(data, pretty: true))
      IO.puts("saved fixture: #{path}")
      {:ok, path}
    end

    defp maybe_save(data, opts) do
      case opts[:save_as] do
        path when is_binary(path) -> save_fixture(data, path)
        _ -> :ok
      end
    end

    def as_user!(opts) do
      case opts[:as] do
        %{} = user -> user
        username when is_binary(username) -> local_user(username)
        _ -> raise "pass `as: user_or_username` — the local user to act as"
      end
    end
  end
end
