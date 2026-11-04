defmodule Bonfire.Federate.ActivityPub.RemoteActorRaceTest do
  @moduledoc """
  Several requests that each make us create the same remote actor at once (eg. signed fetches from someone we haven't met: each misses the key cache and fetches the signer) get that one actor. Each looks the actor up, finds none, and inserts it, so all but one hit the unique index on the character's username: the loser's transaction rolled back, the fetch returned "Could not find or create an actor", and the signed request whose key it was fetching got 401. The loser reads the actor that won instead.

  Committed data, with each task on a connection of its own: the sandbox serialises the transactions of one connection, which would hide the race.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  import Ecto.Query
  import Tesla.Mock

  @moduletag :federation
  @moduletag db_sandbox: false

  alias Bonfire.Data.Identity.Character
  alias Bonfire.Federate.ActivityPub.AdapterUtils

  @tasks 8

  setup do
    # everything committed from here on is removed when the test ends, as a ULID starts with its time
    started = Needle.ULID.generate(System.system_time(:millisecond) - 1)
    started_at = DateTime.utc_now()

    host = "actor-race-#{System.unique_integer([:positive])}.local"
    actor_id = "https://#{host}/users/racer"

    mock_global(fn
      %{method: :get, url: ^actor_id} ->
        json(Simulate.actor_json(actor_id, "racer"))

      _ ->
        %Tesla.Env{status: 404, body: ""}
    end)

    # our service actor signs the fetches, and it and its key are made on first use, which races in the same way when several requests make them at once; that only happens once in an instance's life, so they are made here, before the race this test is about
    made_service_character? =
      match?({:error, :not_found}, Bonfire.Me.Users.by_id(AdapterUtils.service_character_id()))

    {:ok, service_actor} = ActivityPub.Utils.service_actor()
    {:ok, _} = ActivityPub.Safety.Keys.ensure_keys_present(service_actor)

    on_exit(fn -> clean_up(started, started_at, actor_id, made_service_character?) end)

    {:ok, actor_id: actor_id, username: "racer@#{host}"}
  end

  test "fetches of a new actor made at once all get the same actor", %{
    actor_id: actor_id,
    username: username
  } do
    results = at_once(fn -> ActivityPub.Federator.Fetcher.fetch_fresh_object_from_id(actor_id) end)

    failed = Enum.reject(results, &match?({:ok, %ActivityPub.Actor{}}, &1))
    assert failed == [], "#{length(failed)} of #{@tasks} failed: #{inspect(failed, limit: 3)}"

    assert repo().aggregate(from(c in Character, where: c.username == ^username), :count) == 1

    assert {:ok, character} = AdapterUtils.get_character_by_ap_id(actor_id)

    assert results
           |> Enum.map(fn {:ok, actor} -> id(actor.pointer) || actor.pointer_id end)
           |> Enum.uniq() == [id(character)]
  end

  test "signed fetches from a new actor made at once all find the signer's key", %{
    actor_id: actor_id
  } do
    results =
      at_once(fn -> ActivityPub.Safety.HTTP.Signatures.fetch_fresh_public_key(actor_id <> "#main-key") end)

    failed = Enum.reject(results, &match?({:ok, key} when not is_nil(key), &1))
    assert failed == [], "#{length(failed)} of #{@tasks} failed: #{inspect(failed, limit: 3)}"
  end

  defp at_once(fun) do
    1..@tasks
    |> Task.async_stream(
      fn _ ->
        try do
          fun.()
        rescue
          e -> {:raised, e}
        end
      end,
      max_concurrency: @tasks,
      timeout: 60_000
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # the data is committed, so it is removed by hand: every pointer made while the test ran (the actor, the Peer, their circles, feeds and grants, with the rows that reference them), the service actor if the test made it, the actor's AP object, and any `Update` of the service actor queued for delivery while the test ran (with its job), as saving the service actor's key used to queue one. The window needs its upper bound: fixed ids (the built-in circles, ACLs and verbs, the service actor) are readable words that sort far after any ULID of today, so without it they were deleted too
  defp clean_up(started, started_at, actor_id, made_service_character?) do
    ended = Needle.ULID.generate(System.system_time(:millisecond) + 1)

    service_actor_jobs =
      from(j in Oban.Job,
        where:
          j.inserted_at >= ^started_at and
            fragment("?->>'user_id'", j.args) == ^AdapterUtils.service_character_id()
      )

    activities = repo().all(from(j in service_actor_jobs, select: fragment("?->>'activity_id'", j.args)))
    repo().delete_all(from(o in ActivityPub.Object, where: o.id in ^Enum.reject(activities, &is_nil/1)))
    repo().delete_all(service_actor_jobs)

    repo().delete_all(from(p in Needle.Pointer, where: p.id >= ^started and p.id <= ^ended))

    if made_service_character?,
      do:
        repo().delete_all(
          from(p in Needle.Pointer, where: p.id == ^AdapterUtils.service_character_id())
        )

    repo().delete_all(
      from(o in ActivityPub.Object, where: fragment("(?->>'id')", o.data) == ^actor_id)
    )
  end
end
