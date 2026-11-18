defmodule Bonfire.Federate.ActivityPub.DataMigrations.OwnActorRemoteCopies do
  @moduledoc """
  Removes copies of our own actors stored as remote objects before 18 November: an actor of ours listed in full in a document from elsewhere (eg. a collection of moderators or subgroups) was stored as someone else's, with nothing of ours behind it, and its URL then found that copy rather than the actor. On bonfire.cafe, the `Bonfire_Networks` group's copy made every incoming `Join` to it fail ("no local group to act on"); `Federation_Bot` had one too.

  Selects rows of an actor type, stored as remote, whose id is on our host: our actors have no row of their own (they are served from their character), so any such row is a copy. Deletes each and clears what was cached of it, so the URL leads to the actor again. Other rows under our host stored as remote (eg. remote actors' `Update`s under ids minted here) are records of what others did, and are left alone.

  Safe to re-run: once the copies are gone, nothing is selected.
  """

  import Ecto.Query
  use Bonfire.Common.Utils
  alias EctoSparkles.DataMigration
  use DataMigration

  @impl DataMigration
  def base_query do
    from(o in ActivityPub.Object,
      where:
        o.local == false and
          like(fragment("?->>'id'", o.data), ^"#{ActivityPub.Web.base_url()}/%") and
          fragment("?->>'type'", o.data) in ^ActivityPub.Config.supported_actor_types(),
      select: %{id: o.id, ap_id: fragment("?->>'id'", o.data)}
    )
  end

  @impl DataMigration
  def config do
    %DataMigration.Config{
      async: true,
      batch_size: 100,
      throttle_ms: 1_000,
      repo: Bonfire.Common.Repo,
      # `ap_object` ids are UUIDs
      first_id: "00000000-0000-0000-0000-000000000000"
    }
  end

  @impl DataMigration
  def migrate(copies), do: migrate(copies, [])

  # `opts[:repo]` is the repo the migration runs on (the migration passes its own `repo/0`), else the normal one
  @impl DataMigration
  def migrate(copies, opts) do
    repo = Keyword.get(opts, :repo, Bonfire.Common.Repo)

    # the contexts reached from here find their repo through `repo()`, which reads this process: the runner's task when async, which does not inherit the migration's
    if opts[:repo], do: Process.put(:ecto_repo_module, repo)

    Enum.each(copies, &safely(fn -> remove_copy(&1, repo) end, &1))
  end

  defp safely(fun, what) do
    fun.()
  rescue
    e ->
      error(e, "Could not remove the remote copy of our actor #{inspect(what)}, going on")
  catch
    kind, reason ->
      error(
        {kind, reason},
        "Could not remove the remote copy of our actor #{inspect(what)}, going on"
      )
  end

  defp remove_copy(%{id: id, ap_id: ap_id}, repo) do
    repo.delete_all(from(o in ActivityPub.Object, where: o.id == ^id))

    # what was cached of the copy, by its row id and by its URL
    ActivityPub.Object.invalidate_cache(%{
      id: id,
      data: %{"id" => ap_id},
      pointer_id: nil,
      pointer: nil
    })

    # and the actor cached from it, if any: asked now, the URL gives our own actor, whose cache entries are the same keys
    with {:ok, actor} <- ActivityPub.Actor.get_cached(ap_id: ap_id),
         do: ActivityPub.Actor.invalidate_cache(actor)
  end
end
