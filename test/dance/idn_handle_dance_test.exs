defmodule Bonfire.Federate.ActivityPub.Dance.IdnHandleTest do
  @moduledoc """
  A person may type a handle with the Unicode form of an internationalized host (e.g. `@alice@bücher.localhost`), while DNS, HTTP and `acct:` URIs need its A-label (`xn--bcher-kva.localhost`). Run with the second instance on an IDN host, with `just test-federation-dance-idn`. On the usual `localhost` both forms are the same, so this still passes there without exercising the conversion.
  """
  use Bonfire.Federate.ActivityPub.SharedDataDanceCase, async: false

  @moduletag :test_instance

  alias Bonfire.Federate.ActivityPub.AdapterUtils

  test "the remote user is found by a handle with the Unicode form of their host", context do
    "@" <> handle = context[:remote][:username]
    [name, authority] = String.split(handle, "@")

    {host, port} =
      case String.split(authority, ":") do
        [host, port] -> {host, ":" <> port}
        [host] -> {host, ""}
      end

    unicode_handle = "#{name}@#{to_string(:idna.decode(String.to_charlist(host)))}#{port}"

    # on an IDN host the two forms differ, so the lookup below goes through the conversion
    if String.contains?(host, "xn--"), do: refute(unicode_handle == handle)

    assert {:ok, %{"id" => id}} = ActivityPub.Federator.WebFinger.finger(unicode_handle)
    assert id == context[:remote][:canonical_url]

    assert {:ok, user} = AdapterUtils.get_by_url_ap_id_or_username(unicode_handle)
    assert Bonfire.Me.Characters.character_url(user) == context[:remote][:canonical_url]
  end
end
