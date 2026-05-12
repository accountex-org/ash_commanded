defmodule AshCommanded.Commanded.Transformers.GenerateAggregateModule do
  @moduledoc """
  Generates an aggregate module based on the commands and events defined in the DSL.

  For each resource, this transformer will generate an aggregate module that:
  1. Defines a struct representing the aggregate state
  2. Implements the `execute/2` function for handling commands
  3. Implements the `apply/2` function for applying events to the state

  This transformer should run after the command and event module transformers.

  ## Example

  Given a resource with commands and events, this transformer will generate:

  ```elixir
  defmodule MyApp.UserAggregate do
    @moduledoc "Aggregate for User resource"
    
    # Define the aggregate state struct
    defstruct [:id, :email, :name, :status]
    
    # Command handlers
    def execute(%__MODULE__{} = aggregate, %MyApp.Commands.RegisterUser{} = command) do
      # Validate command - in this case, prevent duplicate registration
      if aggregate.id != nil do
        {:error, :user_already_registered}
      else
        # Return event(s) to be applied
        {:ok, %MyApp.Events.UserRegistered{
          id: command.id,
          email: command.email,
          name: command.name
        }}
      end
    end
    
    def execute(%__MODULE__{} = aggregate, %MyApp.Commands.UpdateEmail{} = command) do
      # Validate command - only allow updating existing user
      if aggregate.id == nil do
        {:error, :user_not_found}
      else
        # Return event(s) to be applied
        {:ok, %MyApp.Events.EmailChanged{
          id: command.id,
          email: command.email
        }}
      end
    end
    
    # Event handlers to update state
    def apply(%__MODULE__{} = state, %MyApp.Events.UserRegistered{} = event) do
      %__MODULE__{
        state |
        id: event.id,
        email: event.email,
        name: event.name,
        status: :active
      }
    end
    
    def apply(%__MODULE__{} = state, %MyApp.Events.EmailChanged{} = event) do
      %__MODULE__{
        state |
        email: event.email
      }
    end
  end
  ```
  """

  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer
  alias AshCommanded.Commanded.Transformers.BaseTransformer
  alias AshCommanded.Commanded.Transformers.GenerateCommandModules
  alias AshCommanded.Commanded.Transformers.GenerateEventModules
  alias AshCommanded.Commanded.Error

  @doc """
  Specifies that this transformer should run after the command and event module transformers.
  """
  @impl true
  def after?(GenerateCommandModules), do: true
  def after?(GenerateEventModules), do: true
  def after?(_), do: false

  @doc """
  Transforms the DSL state to generate an aggregate module.

  ## Examples

      iex> transform(dsl_state)
      {:ok, updated_dsl_state}
  """
  @impl true
  def transform(dsl_state) do
    resource_module = Transformer.get_persisted(dsl_state, :module)

    commands = Transformer.get_entities(dsl_state, [:commanded, :commands])
    events = Transformer.get_entities(dsl_state, [:commanded, :events])
    attributes = Transformer.get_entities(dsl_state, [:attributes])

    # Only proceed if there are commands and events defined
    case {commands, events} do
      {[], _} ->
        {:ok, dsl_state}

      {_, []} ->
        {:ok, dsl_state}

      {commands, events} ->
        # Get the previously generated modules from DSL state
        command_modules = Transformer.get_persisted(dsl_state, :command_modules, [])
        event_modules = Transformer.get_persisted(dsl_state, :event_modules, [])

        # Create the aggregate module
        app_prefix = BaseTransformer.get_module_prefix(resource_module)
        resource_name = BaseTransformer.get_resource_name(resource_module)

        aggregate_module = build_aggregate_module(resource_name, app_prefix)

        # Get attribute names to define the struct fields
        attribute_names = Enum.map(attributes, & &1.name)

        # Create the module AST and define it
        ast =
          build_aggregate_module_ast(
            resource_name,
            attribute_names,
            commands,
            events,
            command_modules,
            event_modules,
            dsl_state
          )

        # Skip actual module creation in test environment
        unless Application.get_env(
                 :ash_commanded,
                 :skip_aggregate_module_creation,
                 Mix.env() == :test
               ) do
          BaseTransformer.create_module(aggregate_module, ast, __ENV__)
        end

        # Store the generated module in DSL state
        updated_dsl_state = Transformer.persist(dsl_state, :aggregate_module, aggregate_module)

        {:ok, updated_dsl_state}
    end
  end

  @doc """
  Builds the module name for an aggregate.

  ## Examples

      iex> build_aggregate_module("User", MyApp)
      MyApp.UserAggregate
  """
  def build_aggregate_module(resource_name, app_prefix) do
    Module.concat([app_prefix, "#{resource_name}Aggregate"])
  end

  @doc """
  Builds the AST (Abstract Syntax Tree) for an aggregate module.

  ## Examples

      iex> build_aggregate_module_ast("User", attribute_names, commands, events, command_modules, event_modules)
      {:__block__, [], [{:@, [...], [{:moduledoc, [...], [...]}]}, ...]}
  """
  def build_aggregate_module_ast(
        resource_name,
        attribute_names,
        commands,
        events,
        command_modules,
        event_modules,
        dsl_state \\ nil
      ) do
    # Create a more descriptive moduledoc
    moduledoc = "Aggregate for #{resource_name} resource handling commands and events"

    # Generate struct definition with all attribute fields
    struct_fields = attribute_names |> Enum.map(&{&1, nil})

    # Add version field to struct if not already present - used for snapshotting
    struct_fields =
      if Enum.any?(struct_fields, fn {name, _} -> name == :version end) do
        struct_fields
      else
        struct_fields ++ [{:version, 0}]
      end

    # Generate execute function for each command
    execute_functions =
      generate_execute_functions(commands, events, command_modules, event_modules)

    # Generate apply function for each event
    apply_functions = generate_apply_functions(events, event_modules)

    # Generate snapshot functions - passing application settings from DSL.
    # The application section has no entities (only section-level options), so we use
    # the Dsl.application/1 helper which reads opts via get_opt, not get_entities.
    app_config = if dsl_state, do: AshCommanded.Commanded.Dsl.application(dsl_state), else: nil
    snapshot_functions = generate_snapshot_functions(app_config)

    quote do
      @moduledoc unquote(moduledoc)

      # Import the Error module for standardized error handling
      alias AshCommanded.Commanded.Error
      alias AshCommanded.Commanded.Snapshot
      alias AshCommanded.Commanded.SnapshotStore

      # Define the aggregate state struct with all resource attributes
      defstruct unquote(struct_fields)

      # Snapshot support 
      unquote_splicing(snapshot_functions)

      # Command handlers
      unquote_splicing(execute_functions)

      # Event handlers to update state
      unquote_splicing(apply_functions)
    end
  end

  # Generate execute/2 function for each command
  defp generate_execute_functions(commands, events, command_modules, event_modules) do
    Enum.map(commands, fn command ->
      command_module = command_modules[command.name]

      # Find potential matching event for this command
      # Default to using an event with the same name as the command
      matching_event_name = command.name
      matching_event = Enum.find(events, &(&1.name == matching_event_name))

      event_module = matching_event && event_modules[matching_event.name]

      if command_module && matching_event && event_module do
        # Generate a command handler that returns the matching event
        identity_field = command.identity_field || :id
        action_name = command.action || command.name

        # Determine action type or leave it to be inferred
        action_type_arg =
          if command.action_type do
            quote do: [action_type: unquote(command.action_type)]
          else
            quote do: []
          end

        # Add param mapping if provided
        param_mapping_arg =
          if command.param_mapping do
            quote do: [param_mapping: unquote(command.param_mapping)]
          else
            quote do: []
          end

        # Convert command options into quoted AST elements
        in_transaction_arg =
          quote do
            unquote(if command.in_transaction?, do: [in_transaction?: true], else: [])
          end

        repo_arg =
          quote do
            unquote(if command.repo, do: [repo: command.repo], else: [])
          end

        transaction_timeout_arg =
          quote do
            unquote(
              if command.transaction_timeout,
                do: [transaction_opts: [timeout: command.transaction_timeout]],
                else: []
            )
          end

        transaction_isolation_arg =
          quote do
            unquote(
              if command.transaction_isolation_level,
                do: [transaction_opts: [isolation_level: command.transaction_isolation_level]],
                else: []
            )
          end

        quote do
          @doc """
          Handles the #{unquote(command.name)} command and produces events.

          ## Parameters

          - `aggregate` - The current state of the aggregate
          - `command` - The command to execute

          ## Returns

          - `{:ok, event}` - When command is successfully executed
          - `{:error, error}` - When command execution fails with standardized error
          """
          def execute(%__MODULE__{} = aggregate, %unquote(command_module){} = command) do
            # Extract resource module from command
            resource_module =
              command.__struct__
              |> Module.split()
              # Remove "Commands" and command name
              |> Enum.drop(-2)
              |> Module.concat()

            # Set up command context
            context = %{
              aggregate: aggregate,
              identity_field: unquote(identity_field),
              action_name: unquote(action_name),
              action_type: unquote(command.action_type),
              param_mapping: unquote(command.param_mapping),
              # Add metadata from the command if available
              metadata: Map.get(command, :metadata, %{}),
              # Include command for context reference
              command: command,
              # Include resource for context reference
              resource: resource_module
            }

            # Apply middleware and execute command in a try-rescue block
            try do
              AshCommanded.Commanded.Middleware.CommandMiddlewareProcessor.apply_middleware(
                command,
                resource_module,
                context,
                fn cmd, ctx ->
                  # This is the final handler that runs after all middleware
                  process_command(
                    ctx.aggregate,
                    cmd,
                    resource_module,
                    ctx.action_name,
                    ctx.identity_field,
                    unquote(event_module),
                    unquote(action_type_arg) ++
                      unquote(param_mapping_arg) ++
                      [
                        transforms: unquote(Macro.escape(command.transforms || [])),
                        validations: unquote(Macro.escape(command.validations || []))
                      ] ++
                      unquote(in_transaction_arg) ++
                      unquote(repo_arg) ++
                      unquote(transaction_timeout_arg) ++
                      unquote(transaction_isolation_arg)
                  )
                end
              )
            rescue
              e in _ ->
                {:error,
                 Error.aggregate_error("Error executing command: #{Exception.message(e)}",
                   context: %{
                     command: unquote(command.name),
                     command_module: unquote(command_module),
                     error: inspect(e)
                   }
                 )}
            end
          end

          # Helper function to process a command after middleware has been applied
          defp process_command(
                 aggregate,
                 command,
                 resource_module,
                 action_name,
                 identity_field,
                 event_module,
                 opts
               ) do
            # For a new aggregate - nil id means it doesn't exist yet
            command_id = Map.get(command, identity_field)
            aggregate_id = Map.get(aggregate, identity_field)

            # Extract the middleware context - where we store command execution context
            middleware_context = opts |> Keyword.get(:context, %{})

            # Get context configuration from the command
            include_aggregate? = unquote(command.include_aggregate?)
            include_command? = unquote(command.include_command?)
            include_metadata? = unquote(command.include_metadata?)
            context_prefix = unquote(command.context_prefix)
            static_context = unquote(Macro.escape(command.static_context || %{}))

            # Add aggregate if configured
            middleware_context =
              if include_aggregate? do
                key = if context_prefix, do: :"#{context_prefix}.aggregate", else: :aggregate
                Map.put(middleware_context, key, aggregate)
              else
                middleware_context
              end

            # Add command if configured
            middleware_context =
              if include_command? do
                key = if context_prefix, do: :"#{context_prefix}.command", else: :command
                Map.put(middleware_context, key, command)
              else
                middleware_context
              end

            # Add metadata if present and configured
            middleware_context =
              if include_metadata? && Map.has_key?(command, :metadata) do
                metadata = Map.get(command, :metadata, %{})
                base_key = if context_prefix, do: :"#{context_prefix}.metadata", else: :metadata

                # Either add as a map under metadata key or merge individual keys
                if is_map(metadata) do
                  Map.put(middleware_context, base_key, metadata)
                else
                  middleware_context
                end
              else
                middleware_context
              end

            # Add static context if configured
            middleware_context =
              if static_context && map_size(static_context) > 0 do
                Map.merge(middleware_context, static_context)
              else
                middleware_context
              end

            # Prepare options with context
            action_opts =
              opts ++
                [
                  identity_field: identity_field,
                  context: middleware_context
                ]

            cond do
              # New aggregate (nil aggregate ID)
              is_nil(aggregate_id) ->
                # Implementation for new aggregates
                # Use CommandActionMapper to map command to action with context

                # Convert action result to an event
                case AshCommanded.Commanded.CommandActionMapper.map_to_action(
                       command,
                       resource_module,
                       action_name,
                       action_opts
                     ) do
                  {:ok, result} ->
                    # Return the event with command fields, plus any result data from the action
                    event_data = Map.from_struct(command)

                    # Merge result data if it's a map (for passing additional context)
                    event_data =
                      if is_map(result) and not is_struct(result) do
                        Map.merge(event_data, result)
                      else
                        event_data
                      end

                    {:ok, struct(event_module, event_data)}

                  {:error, reason} ->
                    # Error is already standardized by CommandActionMapper
                    {:error, reason}
                end

              # Existing aggregate, check identity match
              aggregate_id == command_id ->
                # Implementation for existing aggregates
                # Use CommandActionMapper to map command to action with context

                # Convert action result to an event
                case AshCommanded.Commanded.CommandActionMapper.map_to_action(
                       command,
                       resource_module,
                       action_name,
                       action_opts
                     ) do
                  {:ok, result} ->
                    # Return the event with command fields, plus any result data from the action
                    event_data = Map.from_struct(command)

                    # Merge result data if it's a map (for passing additional context)
                    event_data =
                      if is_map(result) and not is_struct(result) do
                        Map.merge(event_data, result)
                      else
                        event_data
                      end

                    {:ok, struct(event_module, event_data)}

                  {:error, reason} ->
                    # Error is already standardized by CommandActionMapper
                    {:error, reason}
                end

              # Identity field mismatch
              true ->
                {:error,
                 Error.aggregate_error("Invalid identity",
                   field: identity_field,
                   value: command_id,
                   context: %{
                     aggregate_id: aggregate_id,
                     command_id: command_id
                   }
                 )}
            end
          end
        end
      else
        # If we can't find a matching event, generate a basic command handler
        # that logs an error and returns a not_implemented error
        quote do
          @doc """
          Handles the #{unquote(command.name)} command.

          ## Parameters

          - `aggregate` - The current state of the aggregate
          - `command` - The command to execute

          ## Returns

          - `{:error, error}` - Not implemented yet with standardized error
          """
          def execute(%__MODULE__{} = _aggregate, %unquote(command_module){} = command) do
            # Log that this command doesn't have a matching event
            require Logger

            Logger.warning(
              "No matching event found for command #{unquote(inspect(command.name))}"
            )

            # Extract resource module from command
            resource_module =
              command.__struct__
              |> Module.split()
              # Remove "Commands" and command name
              |> Enum.drop(-2)
              |> Module.concat()

            # Apply middleware even for not implemented commands
            try do
              AshCommanded.Commanded.Middleware.CommandMiddlewareProcessor.apply_middleware(
                command,
                resource_module,
                %{},
                fn _cmd, _ctx ->
                  {:error,
                   Error.aggregate_error("Command not implemented",
                     context: %{
                       command: unquote(command.name),
                       command_module: unquote(command_module),
                       message: "No matching event handler found for this command"
                     }
                   )}
                end
              )
            rescue
              e in _ ->
                {:error,
                 Error.aggregate_error(
                   "Error executing command middleware: #{Exception.message(e)}",
                   context: %{
                     command: unquote(command.name),
                     command_module: unquote(command_module),
                     error: inspect(e)
                   }
                 )}
            end
          end
        end
      end
    end)
  end

  # Generate apply/2 function for each event
  defp generate_apply_functions(events, event_modules) do
    Enum.map(events, fn event ->
      event_module = event_modules[event.name]

      # Extract fields from the event that will be copied to the aggregate
      event_fields = event.fields

      quote do
        @doc """
        Applies the #{unquote(event.name)} event to the aggregate state.

        ## Parameters

        - `state` - The current state of the aggregate
        - `event` - The event to apply

        ## Returns

        The updated aggregate state
        """
        def apply(%__MODULE__{} = state, %unquote(event_module){} = event) do
          try do
            # Copy event fields to the aggregate state
            changes =
              unquote(event_fields)
              |> Enum.reduce(%{}, fn field, acc ->
                if Map.has_key?(event, field) do
                  Map.put(acc, field, Map.get(event, field))
                else
                  acc
                end
              end)

            # Apply changes to state
            updated_state = Map.merge(state, changes)

            # Increment version when applying events
            updated_state = Map.update(updated_state, :version, 1, &(&1 + 1))

            # Snapshot if configured (no-op when snapshotting is disabled)
            snapshot_state_if_needed(updated_state)
          rescue
            e in _ ->
              # In apply function, we need to return a state and can't report errors
              # So we log the error and return the original state
              require Logger
              Logger.error("Error applying event #{unquote(event.name)}: #{Exception.message(e)}")
              state
          end
        end
      end
    end)
  end

  # Generate snapshot-related functions for the aggregate.
  # app_config is a keyword list from AshCommanded.Commanded.Dsl.application/1 (or nil).
  defp generate_snapshot_functions(app_config) do
    # Extract snapshot configuration from application settings (defaults when app_config is nil)
    snapshotting_enabled = (app_config && Keyword.get(app_config, :snapshotting, false)) || false
    snapshot_threshold = (app_config && Keyword.get(app_config, :snapshot_threshold, 100)) || 100
    snapshot_version = (app_config && Keyword.get(app_config, :snapshot_version, 1)) || 1

    # Default functions that work with or without snapshotting enabled
    default_functions =
      quote do
        @doc """
        Returns the snapshot version for this aggregate.

        ## Returns

        The snapshot version number

        ## Examples

            iex> MyApp.UserAggregate.snapshot_version()
            1
        """
        @spec snapshot_version() :: integer()
        def snapshot_version, do: unquote(snapshot_version)

        @doc """
        Returns the snapshot threshold for this aggregate.
        This is the number of events to process before taking a snapshot.

        ## Returns

        The snapshot threshold

        ## Examples

            iex> MyApp.UserAggregate.snapshot_threshold()
            100
        """
        @spec snapshot_threshold() :: integer()
        def snapshot_threshold, do: unquote(snapshot_threshold)

        @doc """
        Checks if a snapshot should be taken based on the aggregate's version.

        ## Parameters

        - `state` - The current state of the aggregate

        ## Returns

        `true` if a snapshot should be taken, `false` otherwise

        ## Examples

            iex> state = %MyApp.UserAggregate{version: 105}
            iex> MyApp.UserAggregate.should_snapshot?(state)
            true
            
            iex> state = %MyApp.UserAggregate{version: 42}
            iex> MyApp.UserAggregate.should_snapshot?(state)
            false
        """
        @spec should_snapshot?(%__MODULE__{}) :: boolean()
        def should_snapshot?(%__MODULE__{} = state) do
          # Only trigger a snapshot if snapshotting is enabled and
          # the version is a multiple of the threshold
          unquote(snapshotting_enabled) &&
            state.version > 0 &&
            rem(state.version, snapshot_threshold()) == 0
        end
      end

    # When snapshotting is disabled, apply/2 still calls snapshot_state_if_needed/1,
    # so we must define a no-op. When enabled, the snapshot_functions block defines the real implementation.
    no_op_snapshot =
      if snapshotting_enabled do
        []
      else
        quote do
          @doc """
          No-op when snapshotting is disabled; returns state unchanged.
          Defined so apply/2 can always call snapshot_state_if_needed/1.
          """
          @spec snapshot_state_if_needed(%__MODULE__{}) :: %__MODULE__{}
          def snapshot_state_if_needed(%__MODULE__{} = state), do: state
        end
      end

    # Functions that are only generated if snapshotting is enabled
    if snapshotting_enabled do
      snapshot_functions =
        quote do
          @doc """
          Creates a snapshot of the current aggregate state.

          ## Parameters

          - `state` - The current state of the aggregate

          ## Returns

          A new snapshot structure

          ## Examples

              iex> state = %MyApp.UserAggregate{id: "123", name: "John", version: 100}
              iex> MyApp.UserAggregate.create_snapshot(state)
              %AshCommanded.Commanded.Snapshot{
                source_uuid: "123",
                source_type: MyApp.UserAggregate,
                source_version: 1,
                state: state,
                version: 100,
                created_at: ~U[2023-01-01 00:00:00Z]
              }
          """
          @spec create_snapshot(%__MODULE__{}) :: Snapshot.t()
          def create_snapshot(%__MODULE__{} = state) do
            Snapshot.new(state, __MODULE__, state.version, snapshot_version())
          end

          @doc """
          Takes a snapshot of the aggregate if necessary (based on threshold) and saves it.

          ## Parameters

          - `state` - The current state of the aggregate

          ## Returns

          The original state (unchanged)

          ## Examples

              iex> state = %MyApp.UserAggregate{id: "123", name: "John", version: 100}
              iex> MyApp.UserAggregate.snapshot_state_if_needed(state)
              state
          """
          @spec snapshot_state_if_needed(%__MODULE__{}) :: %__MODULE__{}
          def snapshot_state_if_needed(%__MODULE__{} = state) do
            if should_snapshot?(state) do
              snapshot = create_snapshot(state)
              # Save snapshot asynchronously to avoid slowing down command processing
              Task.start(fn -> SnapshotStore.save_snapshot(snapshot) end)
            end

            state
          end

          @doc """
          Gets the latest snapshot for an aggregate.

          ## Parameters

          - `aggregate_id` - The unique identifier of the aggregate

          ## Returns

          - `{:ok, snapshot}` - If a snapshot was found
          - `:error` - If no snapshot was found

          ## Examples

              iex> MyApp.UserAggregate.get_snapshot("user-123")
              {:ok, %AshCommanded.Commanded.Snapshot{...}}
              
              iex> MyApp.UserAggregate.get_snapshot("nonexistent-id")
              :error
          """
          @spec get_snapshot(String.t()) :: {:ok, Snapshot.t()} | :error
          def get_snapshot(aggregate_id) do
            SnapshotStore.get_snapshot(aggregate_id, __MODULE__)
          end

          @doc """
          Restores an aggregate from a snapshot.

          ## Parameters

          - `snapshot` - The snapshot to restore from

          ## Returns

          The restored aggregate state

          ## Examples

              iex> snapshot = %AshCommanded.Commanded.Snapshot{state: %{id: "123", name: "John", version: 42}}
              iex> MyApp.UserAggregate.restore_from_snapshot(snapshot)
              %MyApp.UserAggregate{id: "123", name: "John", version: 42}
          """
          @spec restore_from_snapshot(Snapshot.t()) :: %__MODULE__{}
          def restore_from_snapshot(%Snapshot{} = snapshot) do
            snapshot
            |> Snapshot.state()
            |> ensure_struct()
          end

          # Ensure the restored state is a proper struct of this module
          defp ensure_struct(state) do
            if is_struct(state, __MODULE__) do
              state
            else
              struct(__MODULE__, Map.from_struct(state))
            end
          end
        end

      # Combine default and snapshot-specific functions
      [default_functions, snapshot_functions]
    else
      # If snapshotting is disabled, include no-op so apply/2 compiles
      [default_functions, no_op_snapshot]
    end
  end
end
