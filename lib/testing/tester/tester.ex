# dev/test-only, like `Testing.Interop`: not compiled into prod releases at all
if Application.compile_env(:bonfire, :env) in [:test, :dev] do
  defmodule Bonfire.Federate.ActivityPub.Testing.Tester do
    @moduledoc """
    One side of a test's scenario: our own instance, the dance's other instance, an account on a real server, or an app such as Fedify's CLI. A test is written once against these functions, and runs for each tester that can do what it needs.

    This module is both the behaviour each kind of tester implements and the functions tests call, which dispatch to the tester's module.

    What every tester can do, so every scenario can use:

      * `resolve/2`: something by its URI, as that server knows it: what it holds already, else fetched from us
      * `find_post/2`: what that server makes of a post: its `content` (whatever the server returns, HTML or otherwise), its `tags` (the names as the server gives them), its `media` (each with its `alt` text and `url`), and whether it is `sensitive`. Each server's own forms are kept, so a test comparing across servers normalises for itself
    """

    @enforce_keys [:module, :state]
    defstruct [:module, :state]

    @type t :: %__MODULE__{module: module(), state: term()}

    @typedoc "What a server makes of a post, the same map whichever server it is, so one scenario checks them all; each tester builds it from its server's own form (`Tester.NomadTester.found_post/1` for a Bonfire post or a Mastodon API status)."
    @type found_post :: %{
            content: String.t() | nil,
            tags: [String.t()],
            media: [%{alt: String.t() | nil, url: String.t() | nil}],
            sensitive: boolean()
          }

    @doc "Sets the tester up for a test, from the test's context (eg. the dance's `context[:remote]`)."
    @callback new(context :: map()) :: term()

    @callback resolve(state :: term(), uri :: String.t()) :: {:ok, term()} | {:error, term()}

    @callback find_post(state :: term(), uri :: String.t()) ::
                {:ok, found_post()} | {:error, term()}

    @doc "Posts as the tester's user, from Bonfire's `post_attrs` (each tester translates them to its own form), giving back its own object for the post."
    @callback post(state :: term(), post_attrs :: map()) :: {:ok, term()} | {:error, term()}

    @doc "The URI of a post this tester made (what `post/2` gave back), for a receiver to look up."
    @callback uri_of(state :: term(), post :: term()) :: String.t()

    @doc "Its user follows the actor at `uri`, so what that actor posts is delivered to it; gives back the tester, as following can start something it keeps (Fedify's inbox)."
    @callback follow(state :: term(), uri :: String.t()) :: {:ok, term()} | {:error, term()}

    @doc "Its user stops following the actor at `uri`, for a tester that acts as a real person and so cleans up after a test."
    @callback unfollow(state :: term(), uri :: String.t()) :: {:ok, term()} | {:error, term()}

    @doc "A user there replies to the post at `uri`, from Bonfire's `post_attrs`, giving back its own object for the reply (which `uri_of/2` takes)."
    @callback reply(state :: term(), uri :: String.t(), post_attrs :: map()) ::
                {:ok, term()} | {:error, term()}

    @doc "What it made of the post at `uri` we delivered to it: `{:accepted, how}` or `{:refused, why}`, saying how it knows, for a failure message. Waits for the delivery to arrive."
    @callback delivery_outcome(state :: term(), uri :: String.t()) ::
                {:accepted, term()} | {:refused, term()}

    @doc "What it needs to do `callback` (one of the callbacks above), which `skip_reason/2` turns into a reason to skip: `{:executable, name}` (a program on the `PATH`), `:tunnel` (both instances reachable from the internet, `TUNNELED=yes`)."
    @callback requires(callback :: atom()) :: [{:executable, String.t()} | :tunnel]

    # not every tester can act (Fedify's CLI cannot post)
    @optional_callbacks requires: 1,
                        post: 2,
                        uri_of: 2,
                        follow: 2,
                        unfollow: 2,
                        reply: 3,
                        delivery_outcome: 2

    @doc "A tester of this `module`, set up for a test; `{module, account}` for one whose account is given (`context[:account]`, as `Tester.NomadTester` takes)."
    def new({module, account}, context), do: new(module, Map.put(context, :account, account))
    def new(module, context), do: %__MODULE__{module: module, state: module.new(context)}

    # each callback that only passes the tester's state on to its module, as a function of the same name taking the tester
    for {name, arity} <- [
          resolve: 2,
          find_post: 2,
          post: 2,
          uri_of: 2,
          reply: 3,
          delivery_outcome: 2
        ] do
      args = Macro.generate_arguments(arity - 1, __MODULE__)

      def unquote(name)(%__MODULE__{module: module, state: state}, unquote_splicing(args)),
        do: module.unquote(name)(state, unquote_splicing(args))
    end

    @doc "Follows, giving back the tester, as following can start something it keeps (Fedify's inbox)."
    def follow(%__MODULE__{module: module, state: state} = tester, uri) do
      with {:ok, state} <- module.follow(state, uri), do: {:ok, %{tester | state: state}}
    end

    @doc "Unfollows where the tester has to clean up (a real person's account), and does nothing for the others."
    def unfollow(%__MODULE__{module: module, state: state}, uri) do
      Code.ensure_loaded(module)
      if function_exported?(module, :unfollow, 2), do: module.unfollow(state, uri), else: :ok
    end

    @doc "What a tester of this `module` needs to do `callback` (nothing, unless it says)."
    def requires(module, callback) do
      Code.ensure_loaded(module)
      if function_exported?(module, :requires, 1), do: module.requires(callback), else: []
    end

    @doc "Why a tester of this `module` cannot do what a test uses (`callbacks`) here, for the test's `@tag skip:`, or `false` when it can: a callback it does not have, or something one needs that is missing."
    def skip_reason({module, _account}, callbacks), do: skip_reason(module, callbacks)

    def skip_reason(module, callbacks) do
      Code.ensure_loaded(module)

      Enum.find_value(callbacks, false, fn callback ->
        if has?(module, callback) do
          Enum.find_value(requires(module, callback), false, fn
            {:executable, name} ->
              is_nil(System.find_executable(name)) &&
                "#{inspect(module)} needs `#{name}` on the PATH to #{callback}"

            :tunnel ->
              System.get_env("TUNNELED") != "yes" &&
                "#{inspect(module)} needs both dance instances tunnelled to #{callback}: just test-federation-dance-tunneled"
          end)
        else
          "#{inspect(module)} has no #{callback}"
        end
      end)
    end

    # whether `module` implements `callback`, at the arity the behaviour gives it
    defp has?(module, callback) do
      Enum.any?(__MODULE__.behaviour_info(:callbacks), fn {name, arity} ->
        name == callback and function_exported?(module, name, arity)
      end)
    end
  end
end
