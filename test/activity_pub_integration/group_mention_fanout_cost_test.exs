defmodule Bonfire.Federate.ActivityPub.GroupMentionFanoutCostTest do
  @moduledoc """
  What one Mastodon post that mentions one of our groups costs, step by step, and which part of it grows with the group's followers.

  The post arrives as Mastodon sends it (a `Create{Note}` with the group in `cc` and a `Mention` tag), through the incoming job a delivery to our inbox enqueues. The group then boosts it, and the boost's publish job fans it out to the group's followers. Each step runs the real jobs, nothing patched, and prints:

  - wall time
  - database queries and their time, split between the process that runs the job and all other processes (telemetry handlers are global, and work done in Cachex couriers or tasks would otherwise be missed or put on the wrong step)
  - Oban jobs inserted, by queue and op, with the size of their args
  - how often the functions that check followers and permissions ran (`:erlang.trace_pattern/3` call counts, which count calls in every process)

  Slow, so tagged `:benchmark`, which the default test run excludes. Run it with `just test extensions/bonfire_federate_activitypub/test/activity_pub_integration/group_mention_fanout_cost_test.exs --only benchmark` and grep the output for `FANOUT`.
  """
  use Bonfire.Federate.ActivityPub.DataCase, async: false

  @moduletag :benchmark
  @moduletag timeout: :infinity

  import Tesla.Mock

  alias ActivityPub.Federator.Transformer
  alias ActivityPub.Federator.APPublisher
  alias Bonfire.Classify.Categories

  @public "https://www.w3.org/ns/activitystreams#Public"
  @author "https://mastodon.local/users/writer"

  # functions whose call counts are printed: everything in these modules, so a check that runs once per follower shows up whatever its name
  @traced_modules [
    ActivityPub.Federator.APPublisher,
    ActivityPub.Federator.Publisher,
    ActivityPub.Federator.Adapter,
    ActivityPub.Actor,
    ActivityPub.Instances,
    ActivityPub.Safety.IntegrityProofs.Outgoing,
    Bonfire.Federate.ActivityPub,
    Bonfire.Federate.ActivityPub.Adapter,
    Bonfire.Federate.ActivityPub.AdapterUtils,
    Bonfire.Federate.ActivityPub.Outgoing,
    Bonfire.Boundaries,
    Bonfire.Social.FeedActivities,
    Bonfire.Social.Feeds,
    Bonfire.Social.Graph.Follows,
    Bonfire.Social.Boosts,
    Bonfire.Social.Tags,
    Bonfire.Search
  ]

  @traced_functions [{:public_key, :sign, :_}, {:crypto, :sign, :_}]

  setup do
    # what production logs (`PROD_LOG_LEVEL` defaults to warning), so the test's info-level logging is not what gets measured
    previous_level = Logger.level()
    Logger.configure(level: :warning)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    # setting up hundreds of followers takes longer than the sandbox's ownership timeout, after which the connection is taken away mid-test, so check the connection out again without one. Checking in rolls back what the case template wrote, so its federation settings are written again
    repo = repo()
    Ecto.Adapters.SQL.Sandbox.checkin(repo)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(repo, sandbox: true, ownership_timeout: :infinity)
    Ecto.Adapters.SQL.Sandbox.mode(repo, {:shared, self()})
    Bonfire.Federate.ActivityPub.set_allowlist_only(:instance, false)
    Bonfire.Federate.ActivityPub.set_federating(:instance, true)

    :ok
  end

  # remote followers per host, all Mastodon-shaped, so each host has one shared inbox
  test "cost of a Mastodon post mentioning a group with 50 local and 200 remote followers on 20 hosts" do
    measure("large", 50, 200, 20)
  end

  # The publish job checks whether each follower may receive the post (blocks, federation mode). Done one follower at a time it cost about 9 queries per remote follower, so a group with a few hundred followers held a connection for over a second. Checked all at once, the count depends on the number of inboxes, not remote followers, so with the same local followers and the same 4 hosts the two sizes stay close. Local followers still cost about 3 queries each, as their actors are loaded before being left out, so both sizes have the same 10.
  test "the publish step's queries do not grow with remote followers on the same hosts" do
    small = measure("small", 10, 40, 4) |> publish_queries()
    large = measure("more remote followers, few hosts", 10, 200, 4) |> publish_queries()

    assert large - small <= 50,
           "the publish step made #{small} queries with 40 remote followers and #{large} with 200, on the same 4 hosts"
  end

  defp publish_queries(results) do
    %{queries: queries} = Enum.find(results, &String.starts_with?(&1.label, "2 publish"))
    Enum.reduce(queries, 0, fn {_key, count, _time}, acc -> acc + count end)
  end

  defp measure(name, local_count, remote_count, host_count) do
    setup_started = System.monotonic_time(:millisecond)
    deliveries = :counters.new(2, [])

    mock_global(fn
      %{method: :post, body: body} ->
        :counters.add(deliveries, 1, 1)
        :counters.add(deliveries, 2, IO.iodata_length(body || ""))
        %Tesla.Env{status: 202, body: ""}

      %{method: :get, url: url} ->
        case URI.parse(url) do
          %{path: "/users/" <> username} when not is_nil(username) ->
            if String.contains?(username, "/"),
              do: %Tesla.Env{status: 404, body: ""},
              else: json(Simulate.actor_json(url, username))

          _ ->
            %Tesla.Env{status: 404, body: ""}
        end
    end)

    Process.put(:federating, true)

    creator = fake_user!()
    group = Bonfire.Classify.Simulate.fake_group!(creator)

    assert :ok =
             Bonfire.Classify.Boundaries.replace(group, creator, %{
               membership: "open",
               visibility: "global",
               participation: "anyone",
               default_content_visibility: "public"
             })

    {:ok, group_actor} = ActivityPub.Actor.get_cached(pointer: group)

    for _ <- 1..local_count do
      assert {:ok, _} = Categories.join_and_follow_group(fake_user!(), group)
    end

    # the way a remote follower comes to follow (and, for an open group, join) one of ours: their server sends a Follow
    # a fresh set of actors per run, so a second run in the same test does not reuse the first one's
    run = System.unique_integer([:positive])

    for i <- 1..remote_count do
      actor = "https://host#{rem(i, host_count)}.local/users/follower#{run}x#{i}"

      assert {:ok, _} =
               Transformer.handle_incoming(%{
                 "@context" => "https://www.w3.org/ns/activitystreams",
                 "type" => "Follow",
                 "id" => "#{actor}/follow/#{i}",
                 "actor" => actor,
                 "object" => group_actor.ap_id,
                 "to" => [group_actor.ap_id]
               })
    end

    # the Accepts the follows queued are not what this measures
    drain_all()
    :counters.put(deliveries, 1, 0)
    :counters.put(deliveries, 2, 0)

    follower_ids = Bonfire.Federate.ActivityPub.Adapter.get_follower_local_ids(group_actor)

    IO.puts(
      "FANOUT setup (#{name}): #{length(follower_ids)} followers in #{System.monotonic_time(:millisecond) - setup_started} ms"
    )

    assert length(follower_ids) >= local_count + remote_count,
           "the group should have every follower set up above, got #{length(follower_ids)}"

    create = mastodon_mention(group_actor.ap_id)

    table = :ets.new(:fanout_cost, [:public, :set, write_concurrency: true])
    :ets.insert(table, {:step, nil})
    handler_id = {__MODULE__, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      repo().config()[:telemetry_prefix] ++ [:query],
      &__MODULE__.count_query/4,
      %{table: table, test_pid: test_pid}
    )

    start_call_counts()

    try do
      steps = [
        {"1 receive: the incoming job (post, feeds, notify, the group's boost)",
         fn -> drain_incoming(create) end},
        {"2 publish: the boost's publish job (followers, recipients, one job per inbox)",
         fn -> Oban.drain_queue(queue: :federator_outgoing) end},
        {"3 deliver: every queued delivery (signing, HTTP)",
         fn -> Oban.drain_queue(queue: :federator_outgoing, with_recursion: true) end}
      ]

      results =
        for {label, fun} <- steps do
          run_step(table, label, fun)
        end

      {:ok, ap_object} = ActivityPub.Object.get_cached(ap_id: create["object"]["id"])

      assert %{data: %{"type" => "Announce"}} =
               ActivityPub.Object.get_existing_announce(group_actor.ap_id, ap_object),
             "the group should boost a post that mentions it, or nothing below fans out"

      delivered = :counters.get(deliveries, 1)

      assert delivered >= host_count,
             "the boost should reach every follower's host, got #{delivered} deliveries for #{host_count} hosts"

      # the first suspect again, alone: the follower lookup the publish job does, timed with what it calls
      probes = [
        {"probe: Adapter.get_follower_local_ids/2 (every follower id, unpaged)",
         fn -> ActivityPub.Federator.Adapter.get_follower_local_ids(group_actor, :publish) end},
        {"probe: APPublisher.get_external_followers_except/3 (ids, actors, the federation and block checks)",
         fn -> APPublisher.get_external_followers_except(group_actor, :publish, []) end}
      ]

      probe_results =
        for {label, fun} <- probes do
          run_step(table, label, fun)
        end

      report(
        name,
        local_count,
        remote_count,
        host_count,
        results ++ probe_results,
        delivered,
        :counters.get(deliveries, 2)
      )

      results
    after
      stop_call_counts()
      :telemetry.detach(handler_id)
    end
  end

  # A Mastodon status mentioning the group, shaped as Mastodon sends one: public, the mentioned actor in `cc`, a `Mention` tag (see `fixtures/mastodon/create_reply.json`)
  defp mastodon_mention(group_ap_id) do
    status = "#{@author}/statuses/#{System.unique_integer([:positive])}"

    note = %{
      "id" => status,
      "type" => "Note",
      "summary" => nil,
      "inReplyTo" => nil,
      "published" => "2026-11-03T12:00:00Z",
      "url" => status,
      "attributedTo" => @author,
      "to" => [@public],
      "cc" => ["#{@author}/followers", group_ap_id],
      "sensitive" => false,
      "content" =>
        "<p><span class=\"h-card\" translate=\"no\"><a href=\"#{group_ap_id}\" class=\"u-url mention\">@<span>group</span></a></span> hello group</p>",
      "attachment" => [],
      "tag" => [%{"type" => "Mention", "href" => group_ap_id, "name" => "@group"}]
    }

    %{
      "@context" => "https://www.w3.org/ns/activitystreams",
      "id" => "#{status}/activity",
      "type" => "Create",
      "actor" => @author,
      "published" => note["published"],
      "to" => note["to"],
      "cc" => note["cc"],
      "object" => note
    }
  end

  # what the inbox does with a signed delivery: enqueue it on the queue the router picks, which the real job then handles
  defp drain_incoming(create) do
    worker = ActivityPub.Federator.Worker.ReceiverRouter.route_worker(create, true)
    {:ok, _} = worker.enqueue("incoming_ap_doc", %{"params" => create, "signed_by" => @author})

    for queue <- [:federator_incoming_mentions, :federator_incoming, :federator_incoming_follows],
        do: Oban.drain_queue(queue: queue)
  end

  defp drain_all do
    for queue <- [
          :federator_incoming_mentions,
          :federator_incoming,
          :federator_incoming_follows,
          :federator_outgoing,
          :remote_fetcher
        ],
        do: Oban.drain_queue(queue: queue, with_recursion: true)
  end

  defp run_step(table, label, fun) do
    max_job_id = max_job_id()
    :erlang.garbage_collect()
    reset_call_counts()
    :ets.insert(table, {:step, label})

    {micros, _} = :timer.tc(fun)

    :ets.insert(table, {:step, nil})
    calls = call_counts()

    %{
      label: label,
      ms: div(micros, 1000),
      queries: :ets.match_object(table, {{label, :_, :_}, :_, :_}),
      jobs: jobs_since(max_job_id),
      calls: calls
    }
  end

  @doc false
  def count_query(_event, measurements, metadata, %{table: table, test_pid: test_pid}) do
    case :ets.lookup(table, :step) do
      [{:step, step}] when is_binary(step) ->
        who = if self() == test_pid, do: :job_process, else: :other_processes
        key = {step, who, metadata[:source]}
        time = measurements[:total_time] || 0
        :ets.update_counter(table, key, [{2, 1}, {3, time}], {key, 0, 0})

      _ ->
        :ok
    end
  end

  defp max_job_id do
    repo().one(from(j in Oban.Job, select: max(j.id))) || 0
  end

  defp jobs_since(max_job_id) do
    repo().all(
      from(j in Oban.Job,
        where: j.id > ^max_job_id,
        group_by: [j.queue, fragment("?->>'op'", j.args)],
        select:
          {j.queue, fragment("?->>'op'", j.args), count(j.id),
           sum(fragment("octet_length(?::text)", j.args))}
      )
    )
  end

  defp traced_mfas do
    for spec <- @traced_modules ++ @traced_functions, mfa <- expand(spec), do: mfa
  end

  defp expand({module, function, :_}) do
    Code.ensure_loaded(module)
    for {^function, arity} <- module.module_info(:functions), do: {module, function, arity}
  end

  defp expand(module) when is_atom(module) do
    Code.ensure_loaded(module)
    for {function, arity} <- module.module_info(:functions), do: {module, function, arity}
  end

  defp start_call_counts do
    Process.put(:fanout_traced, traced_mfas())
    Enum.each(Process.get(:fanout_traced), &:erlang.trace_pattern(&1, true, [:call_count]))
  end

  defp reset_call_counts do
    Enum.each(Process.get(:fanout_traced), &:erlang.trace_pattern(&1, :restart, [:call_count]))
  end

  defp stop_call_counts do
    Enum.each(Process.get(:fanout_traced) || [], &:erlang.trace_pattern(&1, false, [:call_count]))
  end

  defp call_counts do
    for mfa <- Process.get(:fanout_traced),
        {:call_count, count} = :erlang.trace_info(mfa, :call_count),
        is_integer(count) and count > 0,
        do: {mfa, count}
  end

  defp report(name, local_count, remote_count, host_count, results, delivered, delivered_bytes) do
    IO.puts(
      "\nFANOUT ===== #{name}: #{local_count} local + #{remote_count} remote followers on #{host_count} hosts; #{delivered} deliveries, #{delivered_bytes} bytes POSTed"
    )

    for %{label: label, ms: ms, queries: queries, jobs: jobs, calls: calls} <- results do
      by_who =
        Enum.group_by(queries, fn {{_, who, _}, _, _} -> who end, fn {_, n, t} -> {n, t} end)

      sums =
        for who <- [:job_process, :other_processes] do
          {n, t} =
            Enum.reduce(by_who[who] || [], {0, 0}, fn {n, t}, {an, at} -> {an + n, at + t} end)

          "#{who}: #{n} queries, #{native_ms(t)} ms in DB"
        end

      IO.puts("FANOUT -- #{label}: #{ms} ms wall; #{Enum.join(sums, "; ")}")

      top_sources =
        queries
        |> Enum.map(fn {{_, who, source}, n, t} -> {who, source, n, t} end)
        |> Enum.sort_by(fn {_, _, n, _} -> -n end)
        |> Enum.take(10)
        |> Enum.map_join(", ", fn {who, source, n, t} ->
          "#{source || "(no source)"}#{if who == :other_processes, do: "[other]"}=#{n}/#{native_ms(t)}ms"
        end)

      IO.puts("FANOUT    queries by table: #{top_sources}")

      jobs_line =
        jobs
        |> Enum.map_join(", ", fn {queue, op, n, bytes} ->
          "#{queue}/#{op}=#{n} (#{bytes} bytes)"
        end)

      IO.puts("FANOUT    jobs inserted: #{if jobs_line == "", do: "none", else: jobs_line}")

      top_calls =
        calls
        |> Enum.sort_by(fn {_, n} -> -n end)
        |> Enum.take(25)
        |> Enum.map_join(", ", fn {{m, f, a}, n} -> "#{inspect(m)}.#{f}/#{a}=#{n}" end)

      IO.puts("FANOUT    calls: #{top_calls}")
    end
  end

  defp native_ms(native),
    do: Float.round(System.convert_time_unit(native, :native, :microsecond) / 1000, 1)
end
