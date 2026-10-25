# dev/test-only, like `Testing.Interop`: not compiled into prod releases at all
if Application.compile_env(:bonfire, :env) in [:test, :dev] do
  defmodule Bonfire.Federate.ActivityPub.Testing.Tester.FedifyTester do
    @moduledoc """
    Fedify's command line tool as a tester: what Fedify makes of what we serve.

    `fedify lookup -r <uri>` fetches a document and prints it as raw JSON (after a few status lines). A URL given on its command line may be a private address, so it reaches the dance's instances with no tunnel. Fedify's CLI cannot act (no command posts, replies or likes), so this tester finds and shows, and follows through its ephemeral inbox (`fedify inbox`, in `FedifyCli.Inbox`), which says what it made of what we deliver to it. That inbox refuses private addresses, so following needs both dance instances tunnelled.
    """
    @behaviour Bonfire.Federate.ActivityPub.Testing.Tester

    alias Bonfire.Federate.ActivityPub.Testing.Interop
    alias __MODULE__.Inbox

    @wait 120

    @impl true
    def new(_context), do: %{}

    # following runs `fedify inbox`, which refuses private addresses, so it needs the tunnels; looking up does not
    @impl true
    def requires(callback) when callback in [:follow, :delivery_outcome],
      do: [{:executable, "fedify"}, :tunnel]

    def requires(_callback), do: [{:executable, "fedify"}]

    # starts its ephemeral inbox following the actor, and waits for its Follow to reach us (counted from before it starts, as it follows before it says who it is)
    @impl true
    def follow(state, uri) do
      since = DateTime.utc_now()

      inbox =
        case ExUnit.Callbacks.start_supervised({Inbox, follow: uri}) do
          {:ok, inbox} ->
            inbox

          # all it printed, as an inspected tuple cuts it off where it matters
          {:error, {{reason, output}, _child}} when is_binary(output) ->
            ExUnit.Assertions.flunk("fedify inbox: #{inspect(reason)}; it printed:\n#{output}")
        end

      actor = Inbox.actor(inbox)

      if Interop.await_incoming([type: "Follow", from: actor], seconds: @wait, since: since) do
        {:ok, Map.put(state, :inbox, inbox)}
      else
        {:error, {:no_follow_from, actor, Inbox.output(inbox)}}
      end
    end

    # accepted once its log says it processed our Create of the post: it processes only what it could verify, and refuses the rest
    @impl true
    def delivery_outcome(%{inbox: inbox}, uri) do
      case ActivityPub.Object.get_activity_for_object_ap_id(uri) do
        %{data: %{"id" => create_id}} ->
          said = "Activity '#{create_id}' has been processed"

          if Inbox.await(inbox, said, @wait),
            do: {:accepted, {:said, said}},
            else: {:refused, {:not_processed, create_id, Inbox.output(inbox)}}

        _ ->
          {:refused, {:no_create_of, uri}}
      end
    end

    @impl true
    def resolve(_state, uri), do: lookup(uri)

    @impl true
    def find_post(_state, uri) do
      with {:ok, document} <- lookup(uri) do
        {:ok,
         %{
           content: document["content"],
           tags:
             for(%{"type" => "Hashtag", "name" => name} <- List.wrap(document["tag"]), do: name),
           media:
             for(
               attachment <- List.wrap(document["attachment"]),
               do: %{alt: attachment["name"], url: href(attachment["url"])}
             ),
           sensitive: document["sensitive"] == true
         }}
      end
    end

    # the document as Fedify fetched it, or why it could not
    defp lookup(uri) do
      case System.cmd("fedify", ["lookup", "-r", uri], stderr_to_stdout: true) do
        {output, 0} ->
          with {:ok, json} <- json_part(output), do: Jason.decode(json)

        {output, status} ->
          {:error, {:fedify_lookup_failed, status, output}}
      end
    end

    # the JSON runs from the first line that opens an object to the last line that closes one; Fedify's status messages come before it ("Looking up the object...") and after it ("Successfully fetched the object.")
    defp json_part(output) do
      output = "\n" <> output

      with {start, _} <- :binary.match(output, "\n{"),
           [_ | _] = ends <- :binary.matches(output, "\n}") do
        {stop, _} = List.last(ends)
        {:ok, binary_part(output, start + 1, stop + 2 - (start + 1))}
      else
        _ -> {:error, {:no_json, output}}
      end
    end

    # an attachment's `url` may be a string, a Link, or a list of them
    defp href(url) when is_binary(url), do: url
    defp href(%{"href" => href}), do: href
    defp href([first | _]), do: href(first)
    defp href(_), do: nil
  end
end
