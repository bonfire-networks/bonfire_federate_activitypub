defmodule Bonfire.Federate.ActivityPub.DataMigrations.DuplicateRemoteMedia do
  @moduledoc """
  Removes the copies of a remote media that each `Update` of it made before 27 October: PeerTube sends one each time a video gets views, and with no AP row for it each made another (on bonfire.cafe, 436 to 652 copies of each of 7 videos, all in feeds).

  Keeps the earliest copy of each (the lowest id) and deletes the others, with their feed activities and mixins (`Bonfire.Social.Objects.do_delete/2`), one at a time so a copy that fails costs only itself. The one kept is then what the AP id leads to: its `Peered` URL, which the next `Update` finds it by, and the AP row's `pointer_id` if there is one. Nothing is federated: the media is someone else's.

  Selects copies by the AP id they hold (`metadata.json_ld.id`), whatever sent them. Safe to re-run: once one copy is left, nothing of it is selected.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  @impl DataMigration
  def base_query do
    # each copy but the earliest of its AP id: a window over the media that hold one, rather than a lookup of the others for each
    numbered =
      from(m in Bonfire.Files.Media,
        where: not is_nil(fragment("?->'json_ld'->>'id'", m.metadata)),
        select: %{
          id: m.id,
          ap_id: fragment("?->'json_ld'->>'id'", m.metadata),
          copy:
            fragment(
              "row_number() OVER (PARTITION BY ?->'json_ld'->>'id' ORDER BY ?)",
              m.metadata,
              m.id
            )
        }
      )

    from(c in subquery(numbered), where: c.copy > 1, select: %{id: c.id, ap_id: c.ap_id})
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      async: true,
      batch_size: 100,
      throttle_ms: 1_000,
      repo: Bonfire.Common.Repo,
      first_id: "00000000000000000000000000"
    }
  end

  @impl DataMigration
  def migrate(copies) do
    Enum.each(copies, &safely(fn -> remove_copy(&1) end, &1))

    copies
    |> Enum.map(& &1.ap_id)
    |> Enum.uniq()
    |> Enum.each(&safely(fn -> lead_to_earliest(&1) end, &1))
  end

  defp safely(fun, what) do
    fun.()
  rescue
    e ->
      error(
        e,
        "Could not clean up the duplicate remote media #{inspect(what)}, going on with the next"
      )
  catch
    kind, reason ->
      error(
        {kind, reason},
        "Could not clean up the duplicate remote media #{inspect(what)}, going on with the next"
      )
  end

  defp remove_copy(%{id: id}) do
    with {:ok, media} <- Bonfire.Files.Media.one(id: id),
         # its activities, `Peered` and mixins; someone else's, so deleted here only, nothing sent
         {:ok, _} <-
           Bonfire.Social.Objects.do_delete(media,
             skip_boundary_check: true,
             skip_federation: true
           ) do
      # its `Peered`, which `do_delete` leaves for a `Media`, and which would keep its AP id leading to it rather than to the copy kept
      Bonfire.Common.Repo.delete_all(
        from(p in Bonfire.Data.ActivityPub.Peered, where: p.id == ^id)
      )

      # removed, not hidden: `do_delete` only sets a `Media`'s own `deleted_at`. The row, not `Media.hard_delete/2`, which also deletes the files: a remote copy's is the origin's URL
      Bonfire.Common.Repo.delete(media, stale_error_field: :id)
    end
  end

  # the copy kept is what its AP id leads to: the `Peered` URL a later `Update` finds it by (`AdapterUtils.pointer_id_from_ap_object/1`), and the AP row, if there is one
  defp lead_to_earliest(ap_id) do
    # `Bonfire.Common.Repo` by name: `use DataMigration` imports `Ecto.Migration`'s `repo/0`
    with [earliest_id | _] <-
           Bonfire.Common.Repo.all(
             from(m in Bonfire.Files.Media,
               where: fragment("?->'json_ld'->>'id'", m.metadata) == ^ap_id,
               order_by: [asc: m.id],
               limit: 1,
               select: m.id
             )
           ) do
      Bonfire.Federate.ActivityPub.Peered.save_canonical_uri(earliest_id, ap_id, type: :object)

      with {:ok, %ActivityPub.Object{pointer_id: pointer_id} = ap_object}
           when pointer_id != earliest_id <- ActivityPub.Object.get_cached(ap_id: ap_id) do
        ActivityPub.Object.do_update_existing(ap_object, %{pointer_id: earliest_id})
      end
    end
  end
end
