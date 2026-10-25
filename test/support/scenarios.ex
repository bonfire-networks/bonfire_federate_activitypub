defmodule Bonfire.Federate.ActivityPub.Testing.Scenarios do
  @moduledoc """
  Each scenario's body, written once against `Testing.Tester`, for the files that run it: a dance file for the dance's other instance and Fedify's CLI, and a file in `test/live_federation/` for real servers' accounts, as live tests are kept out of the dance files.

  Each takes the test's context and its testers (the receiver, or the sender and the receiver for a scenario that runs both ways), and asserts with ExUnit.
  """
  import ExUnit.Assertions

  alias Bonfire.Federate.ActivityPub.Testing.Tester
  alias Bonfire.Federate.ActivityPub.Testing.Interop

  @doc "A public post with hashtags, from the sender to the receiver (us to them, or them to us): the receiver finds it by its URI, and shows its text and its hashtags."
  def posts_hashtags(_context, sender, receiver) do
    assert {:ok, post} =
             Tester.post(sender, %{
               post_content: %{html_body: "test content one with hashtags #elixir #bonfire"}
             })

    url = Tester.uri_of(sender, post)

    assert {:ok, _} = Tester.resolve(receiver, url)

    assert {:ok, %{content: content, tags: tags, media: [], sensitive: false}} =
             Tester.find_post(receiver, url)

    assert content =~ "test content one with hashtags"

    # each server gives tag names its own way ("#Elixir", "elixir"), so compared bare and lowercase
    assert tags |> Enum.map(&(&1 |> String.trim_leading("#") |> String.downcase())) |> Enum.sort() ==
             ["bonfire", "elixir"]
  end

  @doc """
  Our user follows a remote actor (`target`, a handle or URI, a person or a group), and it accepts: our `Follow` references it by id (strict servers cannot parse an embedded actor), and its `Accept` reaches us. Checked on our side, through `Testing.Interop`: what we sent, and what we received. `wait:` is how long to wait for the `Accept`, in seconds (default 90).
  """
  def follow_accepted(context, target, opts \\ []) do
    assert {:ok, actor} = Interop.fetch(target)
    since = DateTime.utc_now()

    us = Tester.new({Tester.NomadTester, :local}, context)
    assert {:ok, _} = Tester.follow(us, actor.ap_id)

    follow =
      Interop.outgoing([type: "Follow", about: actor.ap_id], since) ||
        flunk("we sent no Follow of #{actor.ap_id}")

    assert is_binary(follow.data["object"]),
           "our Follow embeds the actor instead of referencing its id: #{inspect(follow.data["object"])}"

    assert Interop.await_incoming([type: "Accept", from: actor.ap_id],
             seconds: opts[:wait] || 90,
             since: since
           ),
           "no Accept from #{actor.ap_id}: it could not fetch or parse our Follow or our actor, or we dropped its Accept"
  end

  @doc "A post delivered to a follower, us to them: the receiver follows our user, our user posts, and the receiver says it accepted it (`delivery_outcome`). A follower that acts as a real person unfollows at the end."
  def delivery(context, receiver) do
    our_user_url = context[:local][:canonical_url]
    sender = Tester.new(Tester.NomadTester, context)

    assert {:ok, receiver} = Tester.follow(receiver, our_user_url)

    try do
      text = "a post for my followers #{System.unique_integer([:positive])}"
      assert {:ok, post} = Tester.post(sender, %{post_content: %{html_body: text}})

      assert {:accepted, _how} =
               Tester.delivery_outcome(receiver, Tester.uri_of(sender, post))
    after
      cleanup(receiver, our_user_url)
    end
  end

  @doc """
  Inbox forwarding (ActivityPub 7.1.2) with three servers: the `follower` follows our user, a fresh user on the dance's other instance replies to our user's post, and we forward the reply to the follower's inbox, which accepts it (`delivery_outcome`).

  The forward carries the replier's FEP-8b32 proof and our user's HTTP signature, which is not the reply's author's, so a follower accepting it relied on the proof. Nothing is patched: that the follower has the reply at all shows we forwarded it, as it does not follow the replier. A follower that acts as a real person unfollows at the end (`unfollow`).
  """
  def inbox_forwarding(context, follower) do
    our_user_url = context[:local][:canonical_url]

    # signed by its author (FEP-8b32), as only such a reply is forwarded; the calling test restores it
    Application.put_env(:activity_pub, :sign_object_integrity_proofs, true)

    author = Tester.new(Tester.NomadTester, context)
    replier = Tester.new({Tester.NomadTester, {:dance_instance, :remote}}, context)

    assert {:ok, follower} = Tester.follow(follower, our_user_url)

    try do
      # the dance's remote user follows ours too, so our post reaches the replier's instance
      assert {:ok, _} = Tester.follow(replier, our_user_url)

      text = "a post to reply to #{System.unique_integer([:positive])}"
      assert {:ok, post} = Tester.post(author, %{post_content: %{html_body: text}})

      assert {:ok, reply} =
               Tester.reply(replier, Tester.uri_of(author, post), %{
                 post_content: %{html_body: "a reply from the other instance"}
               })

      reply_url = Tester.uri_of(replier, reply)

      # the follower has it, and accepted it on the replier's proof: it does not follow the replier, so it can only have it from our forward
      assert {:accepted, _how} = Tester.delivery_outcome(follower, reply_url)
    after
      cleanup(follower, our_user_url)
    end
  end

  # a follower that acts as a real person unfollows; printed rather than raised, so a failure in the test is not replaced by this one
  defp cleanup(follower, our_user_url) do
    case Tester.unfollow(follower, our_user_url) do
      :ok -> :ok
      {:ok, _} -> IO.puts("cleanup: unfollowed #{our_user_url}")
      other -> IO.puts("cleanup FAILED: could not unfollow #{our_user_url}: #{inspect(other)}")
    end
  end

  @doc "A post's image attachment, us to them: the receiver shows it with its alt text."
  def alt_text(context, receiver) do
    sender = Tester.new(Tester.NomadTester, context)

    alt = "A sunset over the sea #{System.unique_integer([:positive])}"

    # our own user uploads the image, as only our own instance is a sender so far
    {:ok, media} =
      Bonfire.Files.upload(
        Bonfire.Files.ImageUploader,
        context[:local][:user],
        Bonfire.Files.Simulation.image_file(),
        %{metadata: %{"alt" => alt, "label" => "beach.png"}}
      )

    assert {:ok, post} =
             Tester.post(sender, %{
               post_content: %{html_body: "look at this"},
               uploaded_media: [media]
             })

    url = Tester.uri_of(sender, post)

    assert {:ok, _} = Tester.resolve(receiver, url)
    assert {:ok, %{media: [shown_media]}} = Tester.find_post(receiver, url)

    assert shown_media.alt == alt,
           "alt text is the whole point of `name` on an AS2 attachment, so it has to survive the round trip"
  end
end
