defmodule Bonfire.Federate.ActivityPub.ActorDelegation do
  @moduledoc """
  Which remote signers may publish *as* a local actor through that actor's C2S outbox.

  A remote system (e.g. event software on another host) can POST to `/pub/actors/<username>/outbox` authenticated by HTTP signature rather than OAuth, and have the activity created as the local actor. That is impersonation, so it is off unless the instance explicitly allowlists the signer for that actor.

  Configured by the `AP_DELEGATED_ACTORS` env var. Entries are separated by `;`, the local actor's username from its signers by the FIRST `:` (signer URIs contain `:` themselves), and signers from each other by `,`:

      AP_DELEGATED_ACTORS="events:lauti.org;alice:https://social.org/actors/alice,https://alice.org"

  A signer entry is either a bare instance hostname which admits any actor on that instance, or a full actor URI which admits only that actor. A URI like `https://alice.org` is the second kind: it is an instance actor's own id, not a wildcard for its host.

  The lib asks for this via the optional `maybe_delegated_user/2` adapter callback, so nothing in `activity_pub` knows how the decision is made, a future version could express it as a per-user circle/boundary instead, with no change on the lib side.
  """

  import Untangle
  alias ActivityPub.Utils

  @env "AP_DELEGATED_ACTORS"

  @doc """
  Whether `signer` (a remote actor, or its AP ID) may post as the local actor named `username`.
  """
  def delegated?(username, signer) when is_binary(username) do
    with signer_ap_id when is_binary(signer_ap_id) <- Utils.ap_id(signer) do
      username
      |> allowed_signers()
      |> Enum.any?(&matches?(&1, signer_ap_id))
    else
      _ -> false
    end
  end

  def delegated?(_username, _signer), do: false

  @doc """
  The configured signer entries for a local actor's username (empty when none).
  """
  def allowed_signers(username), do: Map.get(config(), username, [])

  @doc """
  The parsed `AP_DELEGATED_ACTORS` var as `%{username => [signer_entry]}`.
  """
  def config, do: parse(System.get_env(@env))

  defp parse(env) when is_binary(env) do
    env
    |> String.split(";", trim: true)
    |> Enum.reduce(%{}, &parse_entry/2)
  end

  defp parse(_), do: %{}

  defp parse_entry(entry, acc) do
    # only the FIRST `:` delimits, everything after it is the signer list, whose URIs contain `:`
    case String.split(entry, ":", parts: 2) do
      [username, signers] ->
        username = String.trim(username)
        signers = split_signers(signers)

        if username == "" or signers == [] do
          warn(entry, "Ignoring #{@env} entry with no username or no signers")
          acc
        else
          Map.update(acc, username, signers, &(&1 ++ signers))
        end

      _ ->
        warn(entry, "Ignoring #{@env} entry, expected `username:signer[,signer]`")
        acc
    end
  end

  defp split_signers(signers) do
    signers
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp matches?(entry, signer_ap_id) do
    entry == signer_ap_id or instance_matches?(entry, signer_ap_id)
  end

  # Compare the signer's AUTHORITY (host + port), never a substring of its URI: a host that merely contains the allowlisted one (`evil-mocked.local`, `mocked.local.evil.com`, `sub.mocked.local`) is a different instance, as is the same host on another port, and the allowlisted name appearing in userinfo/path/query/fragment (`https://mocked.local@evil.com/…`) means nothing.
  defp instance_matches?(entry, signer_ap_id) do
    with host when is_binary(host) <- bare_host_entry(entry),
         %URI{host: signer_host, port: signer_port, scheme: scheme}
         when is_binary(signer_host) and signer_host != "" <- URI.parse(signer_ap_id) do
      String.downcase(signer_host) == host and signer_port == default_port(scheme)
    else
      _ -> false
    end
  end

  # An entry naming a whole instance is a BARE HOSTNAME (`9.dev.bonfire.cafe`) — no scheme, no path.
  # Anything with a scheme is an actor id, including an origin like `https://9.dev.bonfire.cafe`,
  # which is a real actor (an instance actor's own id) rather than a wildcard for its host — so an
  # ambiguous-looking entry resolves to the NARROWER meaning. Hosts are case-insensitive (DNS).
  defp bare_host_entry(entry) do
    case URI.parse(entry) do
      %URI{scheme: nil, host: nil, path: path} when is_binary(path) ->
        unless String.contains?(path, "/"), do: String.downcase(path)

      _ ->
        nil
    end
  end

  defp default_port(scheme) when is_binary(scheme), do: URI.default_port(scheme)
  defp default_port(_scheme), do: nil
end
