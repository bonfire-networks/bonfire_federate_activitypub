defmodule Bonfire.Federate.ActivityPub.DeletePrunedRemotePostTest do
  @moduledoc """
  A remote post we hold, whose copy in the ActivityPub tables was pruned (`ActivityPub.Pruner` deletes remote objects after a retention period, while the post stays), is deleted only by its author, or when its origin says it is gone. A signed `Delete` from some other actor that names it, with a `Tombstone` or a `formerType` of its own making, does not delete it.

  The `Delete` is handed to the receiver worker as the inbox does once the signature held (`signed_by`), as the inbox itself queues a `Delete` for later.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :federation

  import Tesla.Mock

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.Worker.ReceiverHelpers

  @victim "https://mocked.local/users/karen"
  @other "https://mocked.local/users/kip"
  @public "https://www.w3.org/ns/activitystreams#Public"

  setup do
    n = System.unique_integer([:positive])
    post_id = "#{@victim}/statuses/pruned-#{n}"

    serve_origin(post_id, :live)

    assert {:ok, _} = ActivityPub.Actor.get_cached_or_fetch(ap_id: @other)

    assert {:ok, %{pointer: %{id: pointer_id}}} =
             Transformer.handle_incoming(%{
               "type" => "Create",
               "id" => post_id <> "/activity",
               "actor" => @victim,
               "to" => [@public],
               "object" => %{
                 "id" => post_id,
                 "type" => "Note",
                 "attributedTo" => @victim,
                 "content" => "a remote post by the victim",
                 "to" => [@public]
               }
             })

    assert {:ok, _} = Bonfire.Posts.read(pointer_id, skip_boundary_check: true),
           "control: the post was made here"

    %{post_id: post_id, pointer_id: pointer_id}
  end

  # the origin of the post: `:live` serves it, `:gone` answers 410
  defp serve_origin(post_id, state) do
    mock(fn
      %{method: :get, url: @victim} ->
        json(Simulate.actor_json(@victim))

      %{method: :get, url: @other} ->
        json(Simulate.actor_json(@other))

      %{method: :get, url: ^post_id} when state == :live ->
        json(%{
          "@context" => "https://www.w3.org/ns/activitystreams",
          "id" => post_id,
          "type" => "Note",
          "attributedTo" => @victim,
          "content" => "a remote post by the victim",
          "to" => [@public]
        })

      %{method: :get, url: ^post_id} ->
        %Tesla.Env{status: 410, body: ""}

      %{method: :get} ->
        %Tesla.Env{status: 404, body: ""}
    end)
  end

  # what the pruner does to a remote post once it is old enough: its rows in the ActivityPub tables go (the post and the activity that made it), and the cache that served them with them
  defp prune!(post_id) do
    held =
      for id <- [post_id, post_id <> "/activity"],
          {:ok, object} <- [ActivityPub.Object.get_cached(ap_id: id)],
          do: object

    assert length(held) == 2, "control: the post and its activity were held"

    ActivityPub.Pruner.prune_objects(
      prune_orphaned_activities: true,
      remote_post_retention_days: -1
    )

    Enum.each(held, &ActivityPub.Object.invalidate_cache/1)

    for id <- [post_id, post_id <> "/activity"] do
      assert {:error, :not_found} = ActivityPub.Object.get_cached(ap_id: id),
             "control: #{id} is pruned"
    end
  end

  defp post_held?(pointer_id),
    do: match?({:ok, _}, Bonfire.Posts.read(pointer_id, skip_boundary_check: true))

  # the `Delete`, signed (as the receiver worker is told it was verified) by `signer`
  defp deliver_delete(signer, object) do
    doc = %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{signer}/deletes/#{System.unique_integer([:positive])}",
      "type" => "Delete",
      "actor" => signer,
      "to" => [@public],
      "object" => object
    }

    ReceiverHelpers.perform(
      %Oban.Job{
        args: %{
          "op" => "incoming_ap_doc",
          "params" => doc,
          "signed_by" => signer,
          "repo" => ActivityPub.Utils.repo()
        }
      },
      :verified
    )
  end

  describe "a post whose ActivityPub rows are still held" do
    test "sanity: a signed Delete from another actor is refused", ctx do
      deliver_delete(@other, %{"id" => ctx.post_id, "type" => "Tombstone"})

      assert post_held?(ctx.pointer_id)
    end
  end

  describe "a post whose ActivityPub rows were pruned" do
    test "control: a signed Delete from its author deletes it", ctx do
      prune!(ctx.post_id)
      assert post_held?(ctx.pointer_id), "control: the post outlives its pruned rows"

      deliver_delete(@victim, %{"id" => ctx.post_id, "type" => "Tombstone"})

      refute post_held?(ctx.pointer_id)
    end

    test "control: a signed Delete from another actor deletes it when its origin says it is gone",
         ctx do
      prune!(ctx.post_id)
      serve_origin(ctx.post_id, :gone)

      deliver_delete(@other, %{"id" => ctx.post_id, "type" => "Tombstone"})

      refute post_held?(ctx.pointer_id)
    end

    test "a signed Delete from another actor with an inline Tombstone does not delete it while its origin serves it",
         ctx do
      prune!(ctx.post_id)

      deliver_delete(@other, %{"id" => ctx.post_id, "type" => "Tombstone"})

      assert post_held?(ctx.pointer_id), "another actor's Delete removed the author's post"
    end

    test "a signed Delete from another actor with a Tombstone that names a `formerType` does not delete it while its origin serves it",
         ctx do
      prune!(ctx.post_id)

      deliver_delete(@other, %{
        "id" => ctx.post_id,
        "type" => "Tombstone",
        "formerType" => "Note"
      })

      assert post_held?(ctx.pointer_id), "another actor's Delete removed the author's post"
    end

    test "a signed Delete from another actor naming it by its id alone does not delete it while its origin serves it",
         ctx do
      prune!(ctx.post_id)

      deliver_delete(@other, ctx.post_id)

      assert post_held?(ctx.pointer_id), "another actor's Delete removed the author's post"
    end
  end
end
