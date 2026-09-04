# dev/test-only interop probe: not compiled into prod releases at all, so it needs no runtime guards
if Application.compile_env(:bonfire, :env) in [:test, :dev] do
  defmodule Bonfire.Federate.ActivityPub.Testing.Interop.Groups do
    @moduledoc """
    Group-specific interop probes, on top of `Bonfire.Federate.ActivityPub.Testing.Interop`.
    """
    use Bonfire.Common.Utils
    import Untangle

    import Bonfire.Federate.ActivityPub.Testing.Interop

    @doc """
    Runs the full group (for any 1b12 platform) observation flow and reports what we learned:

    1. fetch the community actor (records its shape: attributedTo/moderators, postingRestrictedToMods, featured)
    2. fetch its moderators collection if advertised
    3. follow it as `as:` user, so we start receiving fan-out
    4. wait `wait:` seconds, then report every activity that arrived from that host

    `I.Groups.group_flow("!lemmyworldtest@lemmy.world", as: me, wait: 180)`

    Run it with `AP_CAPTURE_JSON` set and every document involved, fetched or delivered, is recorded verbatim by `Interop.capture/2`. 

    What to look for in the report, per the plan's open questions: are announces `Announce{Create{…}}` (embedded activity) or `Announce{<id>}`; is `audience` set and does the group also appear in to/cc; are thread-starters `Page` with `name` or `Note`; do Like/Delete/moderation activities arrive announced too.
    """
    def group_flow(community, opts \\ []) do
      wait = opts[:wait] || 120
      host = host(community)

      with {:ok, actor} <- fetch(community, opts) do
        fetch_moderators(actor, opts)

        IO.puts("following as #{e(as_user!(opts), :character, :username, "?")} …")
        follow(community, opts)

        IO.puts(
          "waiting #{wait}s for fan-out — post something in that community from another account to see a full round trip"
        )

        Process.sleep(wait * 1000)

        incoming(from: host, limit: opts[:limit] || 50)
      end
    end

    @doc """
    The OUTBOUND half, which no automated test covers: does a remote FILE what one of OUR groups announces?

    Every other probe here has us following them, which only shows what they send. This needs the remote to follow US, and since a tunnel host is not somewhere anyone can be asked to keep an account, you do the follow by hand while this waits.

        # terminal: a tunnelled dev instance, on a bore port the remote has no failure history for
        just dev-federate-tunnel 7

        # in its IEx, with capture on so deliveries and their responses are recorded
        I.Groups.hosted_group_flow(as: "myuser", wait: 600)

    It prints the group's handle, waits for a `Follow` to arrive, publishes a post once one does, and then reports every delivery with the receiver's status and body. What it CANNOT tell you is whether the remote filed the post: check that in the remote's own UI, because our 2xx only means it accepted the payload.

    ⚠️ a remote that has been unable to reach this host backs off per instance (Lemmy waits `1.25^(fail_count - 1)` seconds, capped at a day), so a host used in earlier runs may be silently unreachable for hours. That is what `BORE_PORT`/the bore port argument is for.
    """
    def hosted_group_flow(opts \\ []) do
      me = as_user!(opts)
      wait = opts[:wait] || 600

      group =
        maybe_apply(Bonfire.Classify.Simulate, :fancy_fake_category!, [me, [type: :group]],
          fallback_return: nil
        ) ||
          raise "could not create a group to host"

      IO.puts("""

      ── follow this group from the remote you want to test ─────────
        handle:  @#{group[:username]}
        actor:   #{group[:canonical_url]}
        browse:  #{group[:friendly_url]}
      ───────────────────────────────────────────────────────────────
      waiting #{wait}s for a Follow to arrive …
      """)

      case Interop.await_incoming([type: "Follow"], seconds: wait) do
        nil ->
          IO.puts("no Follow arrived — nothing to measure, so not posting")
          {:error, :no_follower}

        follow ->
          IO.puts("followed by #{inspect(Object.get_ap_id(follow.data["actor"]))} — posting now")

          {:ok, post} =
            Bonfire.Posts.publish(
              current_user: me,
              post_attrs: %{
                post_content: %{
                  html_body:
                    "<p>Bonfire group relay probe #{System.unique_integer([:positive])}</p>"
                }
              },
              publish_in: uid(group[:category]),
              boundary: "public"
            )

          IO.inspect(Interop.outgoing_json(post), label: "the post we published")
          # both shapes of the group's announce, with what each receiver said
          Interop.deliveries()

          IO.puts("\nnow check the remote's UI: a 2xx above only means the payload was accepted")
          {:ok, %{group: group, post: post}}
      end
    end

    @doc """
    Whether the group only accepts posts from its moderators (`postingRestrictedToMods`, a Lemmy extension also emitted by Mbin/PieFed/NodeBB).

    Worth checking before any posting probe: against such a group NO non-mod post can be accepted, so a failure there says nothing about our addressing.
    """
    def posting_restricted?(handle_or_actor, opts \\ [])

    def posting_restricted?(handle, opts) when is_binary(handle) do
      with {:ok, actor} <- fetch(handle, opts), do: posting_restricted?(actor, opts)
    end

    def posting_restricted?(actor, _opts),
      do: e(actor, :data, "postingRestrictedToMods", nil) == true

    @doc "The host part of a group handle or URI."
    def host(handle) do
      URI.parse(normalise_handle(handle)).host ||
        handle |> normalise_handle() |> String.split("@") |> List.last()
    end

    @doc """
    Best-effort fixture directory for a group handle, named by SOFTWARE rather than instance host (fixtures are shared per implementation, eg. "lemmy").

    A guess from the hostname — pass `fixtures:` to override when the host doesn't match the software (eg. a PieFed instance on its own domain).
    """
    def fixtures_dir(handle_or_host, opts \\ []) do
      opts[:fixtures] || software_slug(host(handle_or_host))
    end

    defp software_slug(host) when is_binary(host) do
      host |> String.split(".") |> Enum.at(-2) || host
    end

    defp software_slug(other), do: to_string(other)

    defp fetch_moderators(actor, opts) do
      case e(actor, :data, "attributedTo", nil) do
        url when is_binary(url) ->
          IO.puts("fetching moderators collection: #{url}")

          case ActivityPub.Federator.Fetcher.fetch_object_from_id(url) do
            {:ok, %{data: data}} ->
              IO.inspect(data, label: "moderators collection")

            other ->
              error(other, "could not fetch moderators collection")
          end

        other ->
          IO.puts("no attributedTo moderators collection advertised (#{inspect(other)})")
      end
    end
  end
end
