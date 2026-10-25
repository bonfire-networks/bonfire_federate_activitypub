defmodule Bonfire.Federate.ActivityPub.Nomad.Local do
  @moduledoc """
  `Nomad`'s transport for our own instance, for a local user: runs the local function the context gave, and reads our own database.
  """
  @behaviour Bonfire.Federate.ActivityPub.Nomad

  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @impl true
  def run(fun, args), do: apply(fun, args)

  @impl true
  def resolve(uri, _opts), do: AdapterUtils.get_by_url_ap_id_or_username(uri)

  @impl true
  def find_post(uri, _opts) do
    case AdapterUtils.get_by_url_ap_id_or_username(uri) do
      {:ok, %Bonfire.Data.Social.Post{} = post} -> {:ok, post}
      {:ok, other} -> {:error, {:not_a_post, uri, other}}
      other -> other
    end
  end
end
