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
        I.promote("captured/lemmy.world/Group-1.json", "lemmy/group_actor.json")

    Or run a whole scripted flow and get a report:

        I.Groups.group_flow("!lemmyworldtest@lemmy.world", as: me, wait: 120)

    ## What is real vs what needs the capture hooks

    `incoming/1` reads the `ap_object` table, so it sees activities we successfully INGESTED, as it cannot show payloads we rejected or failed to parse, and stored data is post-normalisation. For verbatim wire capture (including rejects, and including documents we FETCHED rather than received), run with `AP_CAPTURE_JSON=your/directory` which registers `capture/2` as the activity_pub lib's `:document_observer`.
    """

    use Bonfire.Common.Utils
    use Bonfire.Common.Repo
    import Ecto.Query
    import Untangle

    alias Bonfire.Common.EnvConfig
    alias Bonfire.Federate.ActivityPub.AdapterUtils
    alias ActivityPub.Actor
    alias ActivityPub.Object

    # this extension's own test fixtures, resolved from `__DIR__` rather than the cwd: the extension is built from `deps/` in CI and from `extensions/` locally, and only `__DIR__` is right in both
    @default_fixtures_path Path.expand("../../test/fixtures", __DIR__)

    @doc "Where captures and fixtures are written: `AP_CAPTURE_JSON` if set, else this extension's fixture tree."
    def fixtures_path do
      case System.get_env("AP_CAPTURE_JSON") do
        path when is_binary(path) and path not in ["yes", "true", "1"] ->
          if EnvConfig.blank?(path), do: @default_fixtures_path, else: path

        # set as a plain on/off switch rather than a destination, or unset
        _ ->
          @default_fixtures_path
      end
    end

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

    Returns the `ActivityPub.Actor`. Its `.data` is NORMALISED, not what the remote sent, so don't fixture it, run with `AP_CAPTURE_JSON` and `promote/2` the captured document instead.
    """
    def fetch(handle_or_uri, opts \\ []) when is_binary(handle_or_uri) do
      # the binary clause auto-routes: URIs are fetched directly, `name@host` goes via WebFinger
      query = normalise_handle(handle_or_uri)

      case Actor.get_cached_or_fetch(query, opts) do
        {:ok, actor} ->
          summarise_actor(actor)
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
               # `publish_in:` is what makes this a post IN the group rather than one merely addressed to it: the group becomes the object's context, which is where `audience` and the group's place in `to`/`cc` are derived from. Addressing it as a recipient circle instead produced `to: [Public], cc: []` with no reference to the group at all, so the live probe was measuring nothing, and read as "the remote ignored us".
               publish_in: target,
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

    Only shows what we successfully stored; use the `AP_CAPTURE_JSON` hook to also see payloads we rejected.
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

    Filters: `type:` (eg. "Accept"), `from:` (actor ap_id), `about:` (an ap_id the activity's object references, at any nesting), `audience:` (an ap_id it is addressed to, in `audience`/`to`/`cc`). Opts: `seconds:` (default 90), `every:` ms between polls.

        Interop.await_incoming(type: "Accept", from: group.ap_id)
        Interop.await_incoming([type: "Announce", from: group.ap_id, about: post_ap_id], seconds: 180)
        Interop.await_incoming([type: "Create", audience: group.ap_id], seconds: 300)
    """
    def await_incoming(filters, opts \\ []) do
      deadline = System.monotonic_time(:second) + (opts[:seconds] || 90)

      # only rows that arrive from NOW on can satisfy this. Live tests run with `db_sandbox: false`,
      # so everything a previous run ingested is still in the table, and without this an await is
      # satisfied by a stale row: on 2026-09-04 the "remote Accepts our Follow" assertion passed in
      # three consecutive runs on an Accept received hours earlier, while nothing at all was arriving,
      # which hid the reason the announce assertions were failing.
      since = opts[:since] || DateTime.utc_now()
      do_await(filters, deadline, opts[:every] || 3_000, since)
    end

    @doc """
    Polls until an ingested object has a LOCAL pointer, or the timeout passes. Returns the pointer id or nil.

    Storing the AP object and creating the Bonfire object are not the same step: the inbox stores and queues, and the local object appears when that job runs. So a live test that checks for a pointer the moment the activity lands is asking a question the server has not been given time to answer, and will report a bug that is not there.
    """
    def await_pointer(ap_id, opts \\ []) do
      deadline = System.monotonic_time(:second) + (opts[:seconds] || 60)
      do_await_pointer(ap_id, deadline, opts[:every] || 2_000)
    end

    defp do_await_pointer(ap_id, deadline, every) do
      case Object.get_cached(ap_id: ap_id) do
        {:ok, %{pointer_id: pointer_id}} when is_binary(pointer_id) ->
          pointer_id

        _ ->
          if System.monotonic_time(:second) >= deadline do
            nil
          else
            Process.sleep(every)
            do_await_pointer(ap_id, deadline, every)
          end
      end
    end

    defp do_await(filters, deadline, every, since) do
      found =
        from(o in Object,
          where: o.local == false and o.inserted_at >= ^since,
          order_by: [desc: o.id],
          limit: 100
        )
        |> repo().all()
        |> Enum.find(&matches?(&1.data, filters))

      cond do
        found ->
          found

        System.monotonic_time(:second) >= deadline ->
          nil

        true ->
          Process.sleep(every)
          do_await(filters, deadline, every, since)
      end
    end

    defp matches?(data, filters) do
      Enum.all?(filters, fn
        {:type, type} -> data["type"] == type
        {:from, actor} -> Object.get_ap_id(data["actor"]) == actor
        {:about, ap_id} -> references?(data["object"], ap_id)
        {:audience, ap_id} -> addressed_to?(data, ap_id)
        _ -> true
      end)
    end

    @doc """
    Whether an activity (or its embedded object) is ADDRESSED to `ap_id`, in `audience`, `to` or `cc`.

    How a post reaches a group: nothing in `object` names the group, so `references?/2` cannot see it. Implementations disagree about which of the three fields carries it and whether it sits on the activity or the object, so all six places count.
    """
    def addressed_to?(data, ap_id) when is_map(data) do
      Enum.any?(["audience", "to", "cc"], fn field ->
        ap_id in (List.wrap(data[field]) |> Enum.map(&Object.get_ap_id/1))
      end) or addressed_to?(data["object"], ap_id)
    end

    def addressed_to?(_, _), do: false

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

    defp captured_deliveries do
      Path.join([fixtures_path(), "captured", "**", "*.json"])
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        with {:ok, body} <- File.read(path),
             {:ok, %{"received_with" => %{"source" => "delivery"} = context} = capture} <-
               Jason.decode(body) do
          [%{path: path, context: context, document: capture["document"]}]
        else
          _ -> []
        end
      end)
      |> Enum.sort_by(& &1.path, :desc)
    end

    defp print_deliveries(deliveries) do
      IO.puts("\n── deliveries (#{length(deliveries)}) ─────────────")

      for %{context: context, document: document} <- deliveries do
        status = context["status"]
        outcome = if is_integer(status) and status in 200..299, do: "OK ", else: "REJ"

        IO.puts("  #{outcome} #{status} #{document["type"]} → #{context["url"]}")

        # the body is where a receiver says WHY, and the reason we record deliveries at all
        case context["body"] do
          body when is_binary(body) and body != "" ->
            IO.puts("      #{String.slice(body, 0, 300)}")

          _ ->
            :ok
        end
      end

      IO.puts("──────────────────────────────────────────────\n")
    end

    @doc """
    What remotes made of what we SENT: every captured delivery, with the receiver's status and body.

    The outgoing counterpart to `incoming/1`, and the only way to answer "does that implementation accept this shape". A delivery leaves NO trace in `ap_object`, so a 202 and a 400 are equally invisible there; only the `:delivery` observer sees the answer. Needs `AP_CAPTURE_JSON` set, like every other capture.

        I.deliveries()
        I.deliveries(to: "lemmy.world")
        I.deliveries(rejected: true)
    """
    def deliveries(opts \\ []) do
      captured_deliveries()
      |> Enum.filter(fn %{context: context} ->
        (is_nil(opts[:to]) or host_of(context["url"]) =~ opts[:to]) and
          (!opts[:rejected] or context["status"] not in 200..299)
      end)
      |> Enum.take(opts[:limit] || 20)
      |> tap(&print_deliveries/1)
    end

    # ------------------------------------------------------------------
    # recording fixtures
    # ------------------------------------------------------------------

    @doc """
    Promotes a capture into the curated (committed) fixture tree: `promote("captured/lemmy.world/Announce-3.json", "lemmy/announce_create_page.json")`.

    Captures are keyed by host and arrival order, which is right for a research dump and wrong for a fixture a test names. Promoting unwraps the `document` from its capture envelope, so the fixture is exactly the bytes the remote sent.
    """
    def promote(captured_relative_path, to) do
      Path.join(fixtures_path(), captured_relative_path)
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("document")
      |> save_fixture(to)
    end

    @doc """
    Writes a map as a pretty-printed fixture under `fixtures_path()`.

    Prefer `promote/2`: passing `actor.data` or `object.data` here records the POST-transformer form, which makes any test built on it assert that we produce what we produced.
    """
    def save_fixture(data, relative_path) when is_map(data) do
      path = Path.join(fixtures_path(), relative_path)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, Jason.encode!(data, pretty: true))
      IO.puts("saved fixture: #{path}")
      {:ok, path}
    end

    @doc """
    A `:document_observer` for the activity_pub lib: writes every document a remote sends us to disk EXACTLY as it arrived, one file per document, under `fixtures_path()/captured/<host>/<Type>-<n>.json`. Captures land beside the curated fixtures, so promoting one with `save_fixture/2` is a copy.

    Covers BOTH ways a document arrives, activities pushed to our inbox and actors/objects/collections we fetched, since both are wire-format JSON and both get normalised away downstream. The `context` records which, along with the signature and user-agent (inbox) or the URL and status (fetch), since which implementation sent it, and how it signed, is usually the thing being investigated.

    Wired up in `Bonfire.Federate.ActivityPub.RuntimeConfig` whenever `AP_CAPTURE_JSON` is set.

    This is the only way to obtain honest interop fixtures. `incoming/1`, `ap_object.data` and `actor.data` are all post-transformer, so a test built from them asserts that we produce what we produced, and they hold nothing at all for the documents we rejected, which are exactly the interesting ones. Fixtures have to be the wire bytes, including the fields we don't understand yet.
    """
    def capture(document, context) do
      dir = Path.join([fixtures_path(), "captured", document_host(document, context)])
      File.mkdir_p!(dir)

      path = Path.join(dir, "#{safe_name(document["type"])}-#{fingerprint(document)}.json")

      File.write!(
        path,
        Jason.encode!(
          %{"received_with" => normalise_context(context), "document" => document},
          pretty: true
        )
      )

      info(path, "captured #{context[:source]} document")
    end

    # Names the file after the document's CONTENT, not a counter. `System.unique_integer/1` restarts
    # at 1 with each VM, so a second probe run silently overwrote the first run's captures (that is
    # how the `lemmy.world/c/technology` outbox capture was lost to the `c/pics` one). A content
    # hash also makes re-capturing the same document idempotent rather than duplicating it.
    defp fingerprint(document) do
      :crypto.hash(:sha256, :erlang.term_to_binary(document))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 8)
    end

    # header lists aren't JSON-encodable as-is
    defp normalise_context(%{headers: headers} = context) when is_list(headers) do
      %{context | headers: Map.new(headers, fn {k, v} -> {to_string(k), v} end)}
    end

    defp normalise_context(context), do: context

    # a fetched document is filed under the host we fetched it FROM, a pushed one under its actor's host
    defp document_host(_document, %{url: url}) when is_binary(url), do: host_of(url)

    defp document_host(document, _context) do
      case ActivityPub.Object.actor_id_from_data(document) do
        actor when is_binary(actor) -> host_of(actor)
        _ -> host_of(document["id"])
      end
    end

    defp host_of(uri) when is_binary(uri), do: URI.parse(uri).host || "unknown"
    defp host_of(_), do: "unknown"

    # the activity's `type` names the file, and it is whatever the remote sent us — a `"type"` of `"../../.."` must not decide where we write
    defp safe_name(type) when is_binary(type) do
      case String.replace(type, ~r/[^A-Za-z0-9_-]/, "") do
        "" -> "unknown"
        safe -> safe
      end
    end

    defp safe_name(_), do: "unknown"

    def as_user!(opts) do
      case opts[:as] do
        %{} = user -> user
        username when is_binary(username) -> local_user(username)
        _ -> raise "pass `as: user_or_username` — the local user to act as"
      end
    end
  end
end
