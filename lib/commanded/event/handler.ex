defmodule Commanded.Event.Handler do
  @moduledoc """
  Defines the behaviour an event handler must implement and
  provides a convenience macro that implements the behaviour, allowing you to
  handle only the events you are interested in processing.

  You should start your event handlers using a [Supervisor](supervision.html) to
  ensure they are restarted on error.

  # Event handler name

  The name you specify is used when subscribing to the event store. Therefore you
  *should not* change the name once the handler has been deployed. A new
  subscription will be created when you change the name, and you event handler
  will receive already handled events.

  # Subscription options

  You can choose to start the event handler's event store subscription from
  `:origin`, `:current` position, or an exact event number using the `start_from`
  option. The default is to use the origin so your handler will receive *all*
  events.

  Use the `:current` position when you don't want newly created event handlers
  to go through all previous events. An example would be adding an event handler
  to send transactional emails to an already deployed system containing many
  historical events.

  ## Example

  Set the `start_from` option (`:origin`, `:current`, or an explicit event
  number) when using `Commanded.Event.Handler`:

      defmodule AccountBalanceHandler do
        use Commanded.Event.Handler,
          name: "AccountBalanceHandler",
          start_from: :origin
      end

  You can optionally override `:start_from` by passing it as option when
  starting your handler:

      {:ok, _handler} = AccountBalanceHandler.start_link(start_from: :current)

  # Consistency

  For each event handler you can define its consistency, as one of either
  `:strong` or `:eventual`.

  This setting is used when dispatching commands and specifying the `consistency`
  option.

  When you dispatch a command using `:strong` consistency, after successful
  command dispatch the process will block until all event handlers configured to
  use `:strong` consistency have processed the domain events created by the
  command. This is useful when you have a read model updated by an event handler
  that you wish to query for data affected by the command dispatch. With
  `:strong` consistency you are guaranteed that the read model will be
  up-to-date after the command has successfully dispatched. It can be safely
  queried for data updated by any of the events created by the command.

  The default setting is `:eventual` consistency. Command dispatch will return
  immediately upon confirmation of event persistence, not waiting for any event
  handlers.

  ## Example

      defmodule AccountBalanceHandler do
        use Commanded.Event.Handler,
          name: "AccountBalanceHandler",
          consistency: :strong
      end

  """

  use GenServer

  require Logger

  alias Commanded.Event.Handler
  alias Commanded.EventStore
  alias Commanded.EventStore.RecordedEvent
  alias Commanded.Subscriptions

  @type domain_event :: struct
  @type metadata :: struct
  @type subscribe_from :: :origin | :current | non_neg_integer
  @type consistency :: :eventual | :strong

  @doc """
  Optional initialisation callback function called when the handler starts.

  Can be used to start any related processes when the event handler is started.

  Return `:ok` on success, or `{:stop, reason}` to stop the handler process.
  """
  @callback init() :: :ok | {:stop, reason :: any()}

  @doc """
  Event handler behaviour to handle a domain event and its metadata

  Return `:ok` on success, `{:error, :already_seen_event}` to ack and skip the event, or `{:error, reason}` on failure.
  """
  @callback handle(domain_event, metadata) :: :ok | {:error, reason :: any()}

  @doc """
  Macro as a convenience for defining an event handler.

  ## Example

      defmodule ExampleHandler do
        use Commanded.Event.Handler, name: "ExampleHandler"

        def init do
          # ... optional initialisation
          :ok
        end

        def handle(%AnEvent{...}, _metadata) do
          # ...
        end
      end

  Start event handler process (or configure as a worker inside a [supervisor](supervision.html)):

      {:ok, handler} = ExampleHandler.start_link()

  """
  defmacro __using__(opts) do
    quote location: :keep do
      @before_compile unquote(__MODULE__)

      @behaviour Commanded.Event.Handler

      @opts unquote(opts) || []
      @name @opts[:name] || raise "#{inspect __MODULE__} expects :name to be given"

      @doc false
      def start_link(opts \\ []) do
        opts =
          @opts
          |> Keyword.take([:consistency, :start_from])
          |> Keyword.merge(opts)

        Commanded.Event.Handler.start_link(@name, __MODULE__, opts)
      end

      @doc false
      def init, do: :ok

      defoverridable [init: 0]
    end
  end

  # include default fallback function at end, with lowest precedence
  @doc false
  defmacro __before_compile__(_env) do
    quote do
      @doc false
      def handle(_event, _metadata), do: :ok
    end
  end

  defstruct [
    consistency: nil,
    handler_name: nil,
    handler_module: nil,
    last_seen_event: nil,
    subscribe_from: nil,
    subscription: nil,
  ]

  @doc false
  def start_link(handler_name, handler_module, opts \\ []) do
    GenServer.start_link(__MODULE__, %Handler{
      handler_name: handler_name,
      handler_module: handler_module,
      consistency: opts[:consistency] || :eventual,
      subscribe_from: opts[:start_from] || :origin,
    })
  end

  def init(%Handler{handler_module: handler_module} = state) do
    GenServer.cast(self(), :subscribe_to_events)

    reply =
      case handler_module.init() do
        :ok -> :ok
        {:stop, _reason} = reply -> reply
      end

    {reply, state}
  end

  def handle_cast(:subscribe_to_events, %Handler{} = state) do
    {:noreply, subscribe_to_all_streams(state)}
  end

  def handle_info({:events, events}, %Handler{} = state) do
    Logger.debug(fn -> describe(state) <> " received events: #{inspect events}" end)

    try do
      state = Enum.reduce(events, state, &handle_event/2)
      
      {:noreply, state}
    catch
      {:error, reason} ->
        # stop after event handling returned an error
        {:stop, reason, state}
    end
  end

  defp subscribe_to_all_streams(%Handler{consistency: consistency, handler_name: handler_name, subscribe_from: subscribe_from} = state) do
    {:ok, subscription} = EventStore.subscribe_to_all_streams(handler_name, self(), subscribe_from)

    # register this event handler as a subscription with the given consistency
    :ok = Subscriptions.register(handler_name, consistency)

    %Handler{state | subscription: subscription}
  end

  # ignore already seen events
  defp handle_event(%RecordedEvent{event_number: event_number} = event, %Handler{last_seen_event: last_seen_event} = state)
    when not is_nil(last_seen_event) and event_number <= last_seen_event
  do
    Logger.debug(fn -> describe(state) <> " has already seen event ##{inspect event_number}" end)

    confirm_receipt(event, state)
  end

  # delegate event to handler module
  defp handle_event(%RecordedEvent{data: data} = event, %Handler{handler_module: handler_module} = state) do
    case handler_module.handle(data, enrich_metadata(event)) do
      :ok ->
        confirm_receipt(event, state)

      {:error, reason} = error ->
        Logger.error(fn -> describe(state) <> " failed to handle event #{inspect event} due to: #{inspect reason}" end)

        throw(error)
    end
  end

  # confirm receipt of event
  defp confirm_receipt(%RecordedEvent{event_number: event_number} = event, %Handler{} = state) do
    Logger.debug(fn -> describe(state) <> " confirming receipt of event ##{inspect event_number}" end)

    ack_event(event, state)

    %Handler{state | last_seen_event: event_number}
  end

  defp ack_event(event, %Handler{consistency: consistency, handler_name: handler_name, subscription: subscription}) do
    EventStore.ack_event(subscription, event)
    Subscriptions.ack_event(handler_name, consistency, event)
  end

  defp enrich_metadata(%RecordedEvent{metadata: metadata} = event) do
    event
    |> Map.from_struct()
    |> Map.take([:event_number, :stream_id, :stream_version, :created_at])
    |> Map.merge(metadata || %{})
  end

  defp describe(%Handler{handler_module: handler_module}), do: inspect(handler_module)
end
