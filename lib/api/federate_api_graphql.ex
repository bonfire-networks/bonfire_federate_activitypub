if Application.compile_env(:bonfire_api_graphql, :modularity) != :disabled and
     Code.ensure_loaded?(Absinthe.Schema.Notation) do
  defmodule Bonfire.Federate.ActivityPub.API.GraphQL do
    @moduledoc "Federation fields: the instances this one knows."

    use Absinthe.Schema.Notation

    alias Bonfire.Federate.ActivityPub.Instances

    object :federation_queries do
      @desc "Hostnames of the instances this one has federated with, without those it blocks (Mastodon's /api/v1/instance/peers, masto-live-fixes decision 10)"
      field :known_instances, non_null(list_of(non_null(:string))) do
        # Mastodon serves peers to guests (masto-live-fixes decision 9)
        meta(public: true)

        # without instances blocked instance-wide, as Mastodon leaves out suspended domains
        resolve(fn _parent, _args, _info -> {:ok, Instances.list_unblocked_hostnames()} end)
      end
    end
  end
end
