defmodule AshCommanded.Commanded.Sections.ApplicationSection do
  @moduledoc """
  Defines the schema for the `application` section of the Commanded DSL.

  The application section allows configuring a Commanded application for an Ash domain,
  specifying settings such as the event store adapter, pubsub mechanism, and registry.

  ## Example

  ```elixir
  defmodule MyApp.Domain do
    use Ash.Domain

    commanded do
      application do
        otp_app :my_app
        event_store Commanded.EventStore.Adapters.EventStore
        pubsub :local
        registry :local
        include_supervisor? true
        prefix "MyApp"
      end
    end

    # resources...
  end
  ```
  """

  @doc """
  Returns the schema for the application section.
  """
  def schema do
    [
      otp_app: [
        type: :atom,
        doc: "The OTP application name to use for configuration",
        required: true
      ],
      event_store: [
        type: {:or, [:atom, :keyword_list, {:tuple, [:atom, :keyword_list]}]},
        doc: "The event store adapter to use (e.g., Commanded.EventStore.Adapters.EventStore)",
        required: true
      ],
      pubsub: [
        type: :atom,
        doc: "The pub/sub adapter to use (:local, :phoenix)",
        default: :local
      ],
      registry: [
        type: :atom,
        doc: "The registry adapter to use (:local, :global)",
        default: :local
      ],
      snapshotting: [
        type: :boolean,
        doc: "Whether to enable aggregate snapshotting",
        default: false
      ],
      snapshot_threshold: [
        type: :integer,
        doc: "Number of events to process before taking a snapshot",
        default: 100
      ],
      snapshot_version: [
        type: :integer,
        doc: "The version of the snapshot schema",
        default: 1
      ],
      snapshot_store: [
        type: {:or, [:atom, :map]},
        doc: "Optional custom snapshot store module or configuration",
        default: nil
      ],
      include_supervisor?: [
        type: :boolean,
        doc: "Whether to include a supervisor for the application",
        default: false
      ],
      prefix: [
        type: {:or, [:string, {:in, [nil]}]},
        doc: "Application module prefix for generated code",
        default: nil
      ]
    ]
  end

  @doc """
  Returns the entities for the application section.

  The application section doesn't define entities, only configuration options.
  """
  def entities, do: []
end
