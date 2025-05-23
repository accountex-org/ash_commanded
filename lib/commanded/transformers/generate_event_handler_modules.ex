defmodule AshCommanded.Commanded.Transformers.GenerateEventHandlerModules do
  @moduledoc """
  Generates event handler modules based on the event_handlers defined in the DSL.
  
  For each resource with event_handlers, this transformer will generate handler modules
  that subscribe to the events and execute the specified actions or functions.
  
  This transformer should run after the event module transformer.
  
  ## Example
  
  Given a resource with several event_handlers, this transformer will generate:
  
  ```elixir
  defmodule MyApp.EventHandlers.UserNotificationHandler do
    @moduledoc "General purpose event handler for User events"
    
    use Commanded.Event.Handler,
      application: MyApp.CommandedApplication,
      name: "MyApp.EventHandlers.UserNotificationHandler"
      
    def handle(%MyApp.Events.UserRegistered{} = event, _metadata) do
      # Call the action or execute the function defined in the DSL
      MyApp.Notifications.send_welcome_email(event.email)
      :ok
    end
    
    # More handlers for other events...
  end
  ```
  """
  
  use Spark.Dsl.Transformer
  alias Spark.Dsl.Transformer
  alias AshCommanded.Commanded.Transformers.BaseTransformer
  
  @doc """
  Specifies that this transformer should run after the event module transformer.
  """
  @impl true
  def after?(AshCommanded.Commanded.Transformers.GenerateEventModules), do: true
  def after?(_), do: false
  
  @doc """
  Transforms the DSL state to generate event handler modules.
  
  ## Examples
  
      iex> transform(dsl_state)
      {:ok, updated_dsl_state}
  """
  @impl true
  def transform(dsl_state) do
    resource_module = Transformer.get_persisted(dsl_state, :module)
    
    # Get event handlers and events from the DSL
    event_handlers = Transformer.get_entities(dsl_state, [:commanded, :event_handlers])
    events = Transformer.get_entities(dsl_state, [:commanded, :events])
    
    # Only proceed if there are event handlers that should be autogenerated
    case Enum.filter(event_handlers, & &1.autogenerate?) do
      [] ->
        {:ok, dsl_state}
        
      autogen_handlers ->
        # Get the previously generated event modules from DSL state
        event_modules = Transformer.get_persisted(dsl_state, :event_modules, [])
        
        # Group handlers by the handler_name to generate one module per handler name
        handlers_by_name = group_handlers_by_name(autogen_handlers)
        
        app_prefix = BaseTransformer.get_module_prefix(resource_module)
        resource_name = BaseTransformer.get_resource_name(resource_module)
        
        # Generate each handler module and collect their names
        handler_modules = 
          handlers_by_name
          |> Enum.map(fn {handler_name, handlers} ->
            # Build connections between events and handlers
            event_handlers_map = build_event_handlers_map(handlers, events)
            
            # Determine the module name for this handler
            handler_module = build_handler_module(handler_name, resource_name, app_prefix)
            
            # Create the module AST and define it
            ast = build_handler_module_ast(
              resource_module,
              resource_name,
              handlers,
              event_handlers_map,
              event_modules
            )
            
            # Skip actual module creation in test environment
            unless Application.get_env(:ash_commanded, :skip_event_handler_module_creation, Mix.env() == :test) do
              BaseTransformer.create_module(handler_module, ast, __ENV__)
            end
            
            {handler_name, handler_module}
          end)
          |> Map.new()
        
        # Store the generated modules in DSL state
        updated_dsl_state = Transformer.persist(dsl_state, :event_handler_modules, [
          {resource_module, handler_modules}
        ])
        
        {:ok, updated_dsl_state}
    end
  end
  
  @doc """
  Groups handlers by their name or autogenerated name based on resource.
  
  ## Examples
  
      iex> group_handlers_by_name(handlers)
      %{notification_handler: [handler1, handler2], integration_handler: [handler3]}
  """
  def group_handlers_by_name(handlers) do
    handlers
    |> Enum.group_by(
      fn handler ->
        # Use explicit handler_name or default to the original name
        handler.handler_name || handler.name
      end,
      fn handler -> handler end
    )
  end
  
  @doc """
  Builds a map of event names to their corresponding handlers.
  
  ## Examples
  
      iex> build_event_handlers_map(handlers, events)
      %{user_registered: [handler1, handler2], email_changed: [handler3]}
  """
  def build_event_handlers_map(handlers, _events) do
    # We include _events parameter for future validation
    # Group handlers by the events they respond to
    handlers
    |> Enum.flat_map(fn handler ->
      Enum.map(handler.events, fn event_name ->
        {event_name, handler}
      end)
    end)
    |> Enum.group_by(
      fn {event_name, _handler} -> event_name end,
      fn {_event_name, handler} -> handler end
    )
  end
  
  @doc """
  Builds the module name for an event handler.
  
  ## Examples
  
      iex> build_handler_module(:notification_handler, "User", MyApp)
      MyApp.EventHandlers.UserNotificationHandler
  """
  def build_handler_module(handler_name, resource_name, app_prefix) do
    handler_suffix = handler_name 
                    |> to_string() 
                    |> Macro.camelize()
                    |> String.replace_suffix("", "Handler")
    
    Module.concat([app_prefix, "EventHandlers", "#{resource_name}#{handler_suffix}"])
  end
  
  @doc """
  Builds the AST (Abstract Syntax Tree) for an event handler module.
  
  ## Examples
  
      iex> build_handler_module_ast(MyApp.User, "User", handlers, event_map, event_modules)
      {:__block__, [], [{:@, [...], [{:moduledoc, [...], [...]}]}, ...]}
  """
  def build_handler_module_ast(
    resource_module,
    resource_name,
    handlers,
    event_handlers_map,
    event_modules
  ) do
    # Get a unique name for this handler from the first handler in the list
    first_handler = List.first(handlers)
    handler_name = first_handler.handler_name || first_handler.name
    handler_name_str = handler_name |> to_string() |> Macro.camelize()
    
    # Create a descriptive moduledoc
    moduledoc = "General purpose event handler for #{resource_name} events (#{handler_name_str})"
    
    # Generate handle function for each event type
    event_handlers = 
      event_handlers_map
      |> Enum.map(fn {event_name, event_handlers} ->
        build_event_handler(event_name, event_handlers, event_modules)
      end)
    
    # Basic application name - would need to be configurable in production
    application_name = :"#{resource_module}.CommandedApplication"
    event_handler_module_name = "#{resource_module}#{handler_name_str}Handler"
    
    # Check if Commanded module exists, else use stub code
    # This is necessary for testing environments where Commanded isn't available
    if Code.ensure_loaded?(Commanded) do
      quote do
        @moduledoc unquote(moduledoc)
        
        use Commanded.Event.Handler,
          application: unquote(application_name),
          name: unquote(event_handler_module_name)
      end
    else
      quote do
        @moduledoc unquote(moduledoc)
        
        # Define a stub implementation for testing
        def init(config), do: {:ok, config}
      end
    end
    |> then(fn quoted_core ->
      quote do
        unquote(quoted_core)
        
        # Import resource module to get Ash actions
        import unquote(resource_module)
        
        # Event handler functions
        unquote_splicing(event_handlers)
        
        # Helper for executing actions
        defp execute_action(event, action_name) when is_atom(action_name) do
          # Convert event struct to map for action params
          params = Map.from_struct(event)
          Ash.run_action(unquote(resource_module), action_name, params)
        end
        
        # Helper for handling responses
        defp handle_response({:ok, _result}), do: :ok
        defp handle_response({:error, reason}), do: {:error, reason}
        defp handle_response(other), do: other
      end
    end)
  end
  
  # Build an event handler function for a specific event
  defp build_event_handler(event_name, handlers, event_modules) do
    # Look up the event module for this event
    event_module = event_modules[event_name]
    
    # Build the implementation for each handler
    handler_impls = 
      handlers
      |> Enum.map(fn handler ->
        case handler.action do
          nil ->
            # No action specified, just return :ok
            quote do: :ok
            
          action when is_atom(action) ->
            # If action is an atom, it's an Ash action reference
            quote do
              execute_action(event, unquote(action))
              |> handle_response()
            end
            
          quoted_fn ->
            # If action is a quoted function, embed it directly
            quote do
              case unquote(quoted_fn).(event, metadata) do
                {:error, reason} -> {:error, reason}
                other -> handle_response(other)
              end
            end
        end
      end)
    
    # Generate a function to handle all implementations for this event
    quote do
      def handle(%unquote(event_module){} = event, metadata) do
        # Execute each handler implementation
        results = [
          unquote_splicing(handler_impls)
        ]
        
        # If any handler fails, the whole handler fails
        case Enum.filter(results, fn 
          {:error, _} -> true
          _ -> false
        end) do
          [] -> :ok
          [error | _] -> error
        end
      end
    end
  end
end