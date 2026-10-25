# Disabled for now: this posts an activity each context builds by hand (`c2s:`), while C2S is to go through the normal context and federation pipelines instead, the sidecar doing the action here (pending), and its ActivityPub form posted to their outbox, replaced by their server's own copy when it comes back (see the plan "Bring your own identity", C2S). The outbox POST below (with the OAuth token) is likely to be its last step.
#
# defmodule Bonfire.Federate.ActivityPub.Nomad.C2S do
#   @moduledoc """
#   `Nomad`'s transport for a user from elsewhere whose server takes ActivityPub client-to-server posts: posts the object or activity the context gave (`c2s:`, a function of the args giving it) to their outbox (from their actor), with an OAuth bearer token for it in the opts (`c2s_token`), and gives back the activity their server made of it.
#   """
#   @behaviour Bonfire.Federate.ActivityPub.Nomad
#
#   alias Bonfire.Federate.ActivityPub.Nomad
#
#   @impl true
#   def run(build, args) when is_function(build) do
#     opts = Nomad.opts_in(args)
#
#     with token when is_binary(token) <- opts[:c2s_token],
#          outbox when is_binary(outbox) <- outbox(opts),
#          {:ok, %{status: status, body: body}} when status in [200, 201] <-
#            Bonfire.Common.HTTP.post(
#              outbox,
#              Jason.encode!(apply(build, args)),
#              [{"content-type", "application/activity+json"}, {"authorization", "Bearer " <> token}]
#            ) do
#       if is_binary(body), do: Jason.decode(body), else: {:ok, body}
#     else
#       {:ok, %{status: status, body: body}} -> {:error, {:c2s, status, body}}
#       other -> {:error, {:c2s, other}}
#     end
#   end
#
#   # the outbox of the `current_user` in `opts`, as their actor says
#   defp outbox(opts) do
#     with {:ok, actor} <- ActivityPub.Actor.get_cached(pointer: Bonfire.Common.Utils.current_user(opts)),
#          do: actor.data["outbox"]
#   end
# end
