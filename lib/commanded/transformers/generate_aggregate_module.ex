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
      {[], _} -> {:ok, dsl_state}
      {_, []} -> {:ok, dsl_state}
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
        ast = build_aggregate_module_ast(
          resource_name,
          attribute_names,
          commands,
          events,
          command_modules,
          event_modules
        )
        
        # Skip actual module creation in test environment
        unless Application.get_env(:ash_commanded, :skip_aggregate_module_creation, Mix.env() == :test) do
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
    event_modules
  ) do
    # Create a more descriptive moduledoc
    moduledoc = "Aggregate for #{resource_name} resource handling commands and events"
    
    # Generate struct definition with all attribute fields
    struct_fields = attribute_names |> Enum.map(&{&1, nil})
    
    # Generate execute function for each command
    execute_functions = generate_execute_functions(commands, events, command_modules, event_modules)
    
    # Generate apply function for each event
    apply_functions = generate_apply_functions(events, event_modules)
    
    quote do
      @moduledoc unquote(moduledoc)
      
      # Import the Error module for standardized error handling
      alias AshCommanded.Commanded.Error
      
      # Define the aggregate state struct with all resource attributes
      defstruct unquote(struct_fields)
      
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
        action_type_arg = if command.action_type do
          quote do: [action_type: unquote(command.action_type)]
        else
          quote do: []
        end
        
        # Add param mapping if provided
        param_mapping_arg = if command.param_mapping do
          quote do: [param_mapping: unquote(command.param_mapping)]
        else
          quote do: []
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
            resource_module = command.__struct__
              |> Module.split()
              |> Enum.drop(-2)  # Remove "Commands" and command name
              |> Module.concat()
            
            # Set up command context
            context = %{
              aggregate: aggregate,
              identity_field: unquote(identity_field),
              action_name: unquote(action_name),
              action_type: unquote(command.action_type), 
              param_mapping: unquote(command.param_mapping)
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
                    unquote(action_type_arg) ++ unquote(param_mapping_arg) ++ [transforms: unquote(Macro.escape(command.transforms || [])), validations: unquote(Macro.escape(command.validations || []))]
                  )
                end
              )
            rescue
              e in _ ->
                {:error, Error.aggregate_error("Error executing command: #{Exception.message(e)}", 
                  context: %{
                    command: unquote(command.name), 
                    command_module: unquote(command_module),
                    error: inspect(e)
                  }
                )}
            end
          end
          
          # Helper function to process a command after middleware has been applied
          defp process_command(aggregate, command, resource_module, action_name, identity_field, event_module, opts) do
            # For a new aggregate - nil id means it doesn't exist yet
            command_id = Map.get(command, identity_field)
            aggregate_id = Map.get(aggregate, identity_field)

            cond do
              # New aggregate (nil aggregate ID)
              is_nil(aggregate_id) ->
                # Implementation for new aggregates
                # Use CommandActionMapper to map command to action
                opts = opts ++ [identity_field: identity_field]
                
                # Convert action result to an event
                case AshCommanded.Commanded.CommandActionMapper.map_to_action(
                  command, resource_module, action_name, opts
                ) do
                  {:ok, _result} ->
                    # Return the event with command fields
                    {:ok, struct(event_module, Map.from_struct(command))}
                  
                  {:error, reason} ->
                    # Error is already standardized by CommandActionMapper
                    {:error, reason}
                end
              
              # Existing aggregate, check identity match
              aggregate_id == command_id ->
                # Implementation for existing aggregates
                # Use CommandActionMapper to map command to action
                opts = opts ++ [identity_field: identity_field]
                
                # Convert action result to an event
                case AshCommanded.Commanded.CommandActionMapper.map_to_action(
                  command, resource_module, action_name, opts
                ) do
                  {:ok, _result} ->
                    # Return the event with command fields
                    {:ok, struct(event_module, Map.from_struct(command))}
                  
                  {:error, reason} ->
                    # Error is already standardized by CommandActionMapper
                    {:error, reason}
                end
              
              # Identity field mismatch
              true ->
                {:error, Error.aggregate_error("Invalid identity", 
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
            Logger.warning("No matching event found for command #{unquote(inspect(command.name))}")
            
            # Extract resource module from command
            resource_module = command.__struct__
              |> Module.split()
              |> Enum.drop(-2)  # Remove "Commands" and command name
              |> Module.concat()
            
            # Apply middleware even for not implemented commands
            try do
              AshCommanded.Commanded.Middleware.CommandMiddlewareProcessor.apply_middleware(
                command,
                resource_module,
                %{},
                fn _cmd, _ctx -> 
                  {:error, Error.aggregate_error("Command not implemented", 
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
                {:error, Error.aggregate_error("Error executing command middleware: #{Exception.message(e)}", 
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
            changes = unquote(event_fields)
              |> Enum.reduce(%{}, fn field, acc ->
                if Map.has_key?(event, field) do
                  Map.put(acc, field, Map.get(event, field))
                else
                  acc
                end
              end)
            
            # Apply changes to state
            Map.merge(state, changes)
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
end