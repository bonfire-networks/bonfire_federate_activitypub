defmodule Bonfire.Federate.ActivityPub.ServiceActorRaceTest do
  @moduledoc """
  Our service actor, which signs our fetches, and its signing key are made on first use: each request looks for them, finds none, and makes them. So the first requests of a new instance that arrive together all make them at once, and all but one hit a unique index (the service character's id is fixed, and so is the row that holds its key): the losers raised or returned an error, and a request that needed the actor to sign got nothing. The loser reads what won instead.

  Committed data, with each task on a connection of its own: the sandbox serialises the transactions of one connection, which would hide the race.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Ecto.Query

  @moduletag :federation
  @moduletag db_sandbox: false

  alias Bonfire.Data.Identity.Account
  alias Bonfire.Data.Identity.Accounted
  alias Bonfire.Data.Identity.Caretaker
  alias Bonfire.Data.Identity.Character
  alias Bonfire.Data.AccessControl.Encircle
  alias Bonfire.Data.AccessControl.Grant
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @tasks 8

  setup do
    service_id = AdapterUtils.service_character_id()

    # the race is in making them, so it can only be seen while there is no service actor: one in the shared DB is not ours to delete
    assert {:error, :not_found} = Bonfire.Me.Users.by_id(service_id),
           "a committed service character is already in the test DB, made by something else"

    started = Needle.ULID.generate(System.system_time(:millisecond) - 1)
    started_at = DateTime.utc_now()

    on_exit(fn -> clean_up(service_id, started, started_at) end)

    {:ok, service_id: service_id}
  end

  test "requests that need the service actor at once all get the same one, with one key", %{
    service_id: service_id
  } do
    results = at_once(fn -> ActivityPub.Utils.service_actor() end)

    failed =
      Enum.reject(
        results,
        &match?({:ok, %ActivityPub.Actor{keys: keys}} when is_binary(keys), &1)
      )

    assert failed == [], "#{length(failed)} of #{@tasks} failed: #{inspect(failed, limit: 3)}"

    assert results
           |> Enum.map(fn {:ok, actor} -> actor.pointer_id || id(actor.pointer) end)
           |> Enum.uniq() ==
             [service_id]

    assert repo().aggregate(from(c in Character, where: c.id == ^service_id), :count) == 1

    assert [stored_key] = stored_keys(service_id)
    assert results |> Enum.map(fn {:ok, actor} -> actor.keys end) |> Enum.uniq() == [stored_key]
  end

  test "requests that need the service actor's key at once all get the key that was saved", %{
    service_id: service_id
  } do
    # the character first, without a key, so only the key is made at once
    character = AdapterUtils.get_or_create_service_character()
    assert id(character) == service_id
    assert stored_keys(service_id) == []

    results =
      at_once(fn ->
        ActivityPub.Safety.Keys.ensure_keys_present(AdapterUtils.character_to_actor(character))
      end)

    failed = Enum.reject(results, &match?({:ok, %{keys: keys}} when is_binary(keys), &1))
    assert failed == [], "#{length(failed)} of #{@tasks} failed: #{inspect(failed, limit: 3)}"

    # a request that signs with a key other than the saved one signs with a key no one can check
    assert [stored_key] = stored_keys(service_id)
    assert results |> Enum.map(fn {:ok, actor} -> actor.keys end) |> Enum.uniq() == [stored_key]
  end

  defp stored_keys(service_id) do
    repo().all(
      from(a in Bonfire.Data.ActivityPub.Actor,
        where: a.id == ^service_id and not is_nil(a.signing_key),
        select: a.signing_key
      )
    )
  end

  defp at_once(fun) do
    1..@tasks
    |> Task.async_stream(
      fn _ ->
        try do
          fun.()
        rescue
          e -> {:raised, Exception.format(:error, e, Enum.take(__STACKTRACE__, 8))}
        end
      end,
      max_concurrency: @tasks,
      timeout: 60_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # the data is committed, so it is removed by hand, and only what the test made: the service character, what it is the caretaker of (its circles and ACLs) and the grants in those ACLs or to it, its feeds and the circle memberships it got, and its account. Making a user also makes its account first, on its own, so a request that lost the race can leave an account with no user: those are the accounts made while the test ran that hold no other user.
  defp clean_up(service_id, started, started_at) do
    ended = Needle.ULID.generate(System.system_time(:millisecond) + 1)

    feeds =
      repo().all(
        from(c in Character,
          where: c.id == ^service_id,
          select: [c.inbox_id, c.outbox_id, c.notifications_id]
        )
      )
      |> List.flatten()

    caretaken =
      repo().all(from(c in Caretaker, where: c.caretaker_id == ^service_id, select: c.id))

    encircles = repo().all(from(e in Encircle, where: e.subject_id == ^service_id, select: e.id))

    # a grant's row goes with its ACL, but its pointer stays unless deleted too
    grants =
      repo().all(
        from(g in Grant,
          where: g.acl_id in ^caretaken or g.subject_id == ^service_id,
          select: g.id
        )
      )

    accounts =
      repo().all(
        from(a in Account,
          left_join: u in Accounted,
          on: u.account_id == a.id,
          where: a.id >= ^started and a.id <= ^ended,
          where: is_nil(u.id) or u.id == ^service_id,
          select: a.id
        )
      )

    ids =
      Enum.reject([service_id | feeds ++ caretaken ++ encircles ++ grants ++ accounts], &is_nil/1)

    repo().delete_all(from(p in Needle.Pointer, where: p.id in ^ids))

    # saving its key used to queue an `Update` of the service actor for delivery: the activity and its job are removed, those queued while the test ran
    jobs =
      from(j in Oban.Job,
        where: j.inserted_at >= ^started_at and fragment("?->>'user_id'", j.args) == ^service_id
      )

    activities = repo().all(from(j in jobs, select: fragment("?->>'activity_id'", j.args)))

    repo().delete_all(
      from(o in ActivityPub.Object, where: o.id in ^Enum.reject(activities, &is_nil/1))
    )

    repo().delete_all(jobs)
  end
end
