
## Overview

AshCommanded is an Elixir library that provides Command Query Responsibility Segregation (CQRS) and Event-Sourcing (ES) patterns for the Ash Framework. It extends Ash resources with a Commanded DSL that enables defining commands, events, and projections. The extension relies on the excellent [Commanded](https://hexdocs.pm/commanded/Commanded.html) library. The Commanded Guides section explained the different concepts better than I could.

Special thanks to [Ben Smith](https://github.com/slashdotdash) for the Commanded library and to [Barnabas J.] for letting me steal the library name.

## Build and Test Commands

```bash
# Install dependencies
mix deps.get

# Compile the project
mix compile

# Run all tests
mix test

# Run specific test file
mix test path/to/test_file.exs:

# Run specific test with line number
mix test path/to/test_file.exs:42:

# Run tests with coverage
mix test --cover:
```

## Architecture

AshCommanded is built as a DSL extension for Ash Framework resources. Its main components are:

1. **DSL Extension**: The `AshCommanded.Commanded.Dsl` module defines four main sections:
   - `commands`: Define commands that trigger state changes
   - `events`: Define events that are emitted by commands
   - `projections`: Define how events affect the resource state
   - `application`: Configure Commanded application settings

2. **Code Generation**: The library dynamically generates Elixir modules:
   - Command modules (structs with typespecs)
   - Event modules (structs with typespecs)
   - Projection modules (with event handlers)
   - Projector modules (Commanded event handlers that apply projections)
   - Aggregate modules (for Commanded integration)
   - Router modules (for command dispatching)
   - Commanded application modules (with projector supervision)

3. **Transformers**: The DSL uses transformers to generate code:
   - `GenerateCommandModules`: Generates command structs
   - `GenerateEventModules`: Generates event structs
   - `GenerateProjectionModules`: Generates projection modules
   - `GenerateProjectorModules`: Generates Commanded event handlers that process events
   - `GenerateAggregateModule`: Generates aggregate module for Commanded
   - `GenerateDomainRouterModule`: Generates router module for each domain
   - `GenerateMainRouterModule`: Generates main application router
   - `GenerateCommandedApplication`: Generates Commanded application with projector supervision

4. **Verifiers**: Validate DSL usage:
   - Command validation (names, fields, handlers, etc.)
   - Event validation (names, fields, etc.)
   - Projection validation (events, actions, changes, etc.)

## Usage Example

```elixir
defmodule ECommerce.Customer do
  use Ash.Resource,
    extensions: [AshCommanded.Commanded.Dsl]

  attributes do
    uuid_primary_key :id
    attribute :name, :string
    attribute :email, :string
    attribute :status, :atom, constraints: [one_of: [:pending, :active]]
  end

  identities do
    identity :unique_id, [:id]
  end

  actions do
    defaults [:read]

    create :register do
      accept [:name, :email]
      change set_attribute(:status, :pending)
    end

    update :confirm_email do
      accept []
      change set_attribute(:status, :active)
    end
  end

  commanded do
    commands do
      command :register_customer do
        fields([:id, :name, :email])
        identity_field(:id)
        action :register
      end

      command :confirm_email do
        fields([:id])
        identity_field(:id)
        action :confirm_email
      end
    end

    events do
      event :customer_registered do
        fields([:id, :name, :email])
      end

      event :email_confirmed do
        fields([:id])
      end
    end

    projections do
      projection :customer_registered do
        action(:create)
        changes(%{
          status: :pending
        })
      end

      projection :email_confirmed do
        action(:update_by_id)
        changes(%{
          status: :active
        })
      end
    end
  end
end
```

This will generate:
- `ECommerce.Commands.RegisterCustomer` - Command struct
- `ECommerce.Events.CustomerRegistered` - Event struct
- `ECommerce.Projections.CustomerRegistered` - Projection definition
- `ECommerce.Projectors.CustomerProjector` - Commanded event handler for projections
- `ECommerce.CustomerAggregate` - Aggregate module
- `ECommerce.Store.Router` - Domain-specific router (if in an Ash.Domain)
- `AshCommanded.Router` - Main application router

## Documentation

AshCommanded provides comprehensive documentation that can be generated locally:

```bash
# Install dependencies
mix deps.get

# Generate cheatsheet and docs
mix gen.docs
```

The documentation includes:
- Guides for commands, events, projections, and routers
- API reference for all modules
- Cheatsheets for the DSL

## Commands

Commands define the actions that can be performed on your resources. AshCommanded generates command modules as structs with typespecs.

```elixir
commanded do
  commands do
    command :register_customer do
      fields([:id, :name, :email])
      identity_field(:id)
      action :register
    end

    command :confirm_email do
      fields([:id])
      identity_field(:id)
      action :confirm_email
    end
  end
end
```

Generated command modules include:

- A struct with the specified fields
- Typespecs for all fields
- Standard module documentation

Example generated command:
```elixir
defmodule ECommerce.Commands.RegisterCustomer do
  @moduledoc """
  Command for registering a new customer
  """
  
  @type t :: %__MODULE__{
    id: String.t(),
    email: String.t(),
    name: String.t(),
    status: atom()
  }
  
  defstruct [:id, :email, :name, :status]
end
```

## Command Handlers

Command handlers are modules that process commands and apply business logic. AshCommanded generates handler modules that invoke Ash actions.

```elixir
defmodule AshCommanded.Commanded.CommandHandlers.CustomerHandler do
  @behaviour Commanded.Commands.Handler
  
  def handle(%ECommerce.Commands.RegisterCustomer{} = cmd, _metadata) do
    Ash.run_action(ECommerce.Customer, :register, Map.from_struct(cmd))
  end
  
  def handle(%ECommerce.Commands.ConfirmEmail{} = cmd, _metadata) do
    Ash.run_action(ECommerce.Customer, :confirm_email, Map.from_struct(cmd))
  end
end
```

Handler options:
- `handler_name` - Custom function name for the handler clause
- `action` - Specify a different Ash action to call (defaults to command name)
- `autogenerate_handler?` - Set to false to disable handler generation

## Events

Events represent facts that have occurred in your system. AshCommanded generates event modules as structs with typespecs.

```elixir
commanded do
  events do
    event :customer_registered do
      fields([:id, :name, :email])
    end

    event :email_confirmed do
      fields([:id])
    end
  end
end
```

Generated event modules include:
- A struct with the specified fields
- Typespecs for all fields
- Standard module documentation

Example generated event:
```elixir
defmodule ECommerce.Events.CustomerRegistered do
  @moduledoc """
  Event emitted when a customer is registered
  """
  
  @type t :: %__MODULE__{
    id: String.t(),
    email: String.t(),
    name: String.t(),
    status: atom()
  }
  
  defstruct [:id, :email, :name, :status]
end
```

## Aggregates and Events-Handlers

Aggregates process events and update state. AshCommanded generates aggregate modules for each resource.
Each event that mutate state is handled by the Aggregate via an apply function that is automatically generated for you.
```elixir
defmodule ECommerce.CustomerAggregate do
  defstruct [:id, :email, :name, :status]
  
  # Apply event to update the aggregate state
  def apply(%__MODULE__{} = state, %ECommerce.Events.CustomerRegistered{} = event) do
    %__MODULE__{
      state |
      id: event.id,
      email: event.email,
      name: event.name
    }
  end
  
  def apply(%__MODULE__{} = state, %ECommerce.Events.EmailConfirmed{} = event) do
    %__MODULE__{state | status: :active}
  end
end
```

The aggregate maintains the current state by applying events in sequence. Each event handler updates specific fields based on the event data.

## Projections

Projections define how events should update your read models. AshCommanded generates projection modules that handle specific event types.

```elixir
commanded do
  projections do
    projection :customer_registered do
      action(:create)
      changes(%{
        status: :pending
      })
    end

    projection :email_confirmed do
      action(:update_by_id)
      changes(%{
        status: :active
      })
    end
  end
end
```

Projection options:
- `action` - The Ash action to perform (`:create`, `:update`, `:destroy`, etc.)
- `changes` - Static map or function that returns the changes to apply
- `autogenerate?` - Set to false to disable projection generation


## Projectors

Projectors are Commanded event handlers that listen for domain events and update read models. AshCommanded automatically generates projector modules using the `GenerateProjectorModules` transformer. These projectors:

1. Subscribe to specific event types defined in your resource
2. Process events using the Commanded event handling system
3. Apply changes to your resources via Ash actions (create, update, destroy)

For example, a generated projector might look like:

```elixir
defmodule ECommerce.Projectors.CustomerProjector do
  use Commanded.Projections.Ecto, name: "ECommerce.Projectors.CustomerProjector"

  project(%ECommerce.Events.CustomerRegistered{} = event, _metadata, fn _context ->
    Ash.Changeset.new(ECommerce.Customer, event)
    |> Ash.Changeset.for_action(:create, %{status: :pending})
    |> Ash.create()
  end)
  
  project(%ECommerce.Events.EmailConfirmed{} = event, _metadata, fn _context ->
    Ash.Changeset.new(ECommerce.Customer, %{id: event.id})
    |> Ash.Changeset.for_action(:update, %{status: :active})
    |> Ash.update()
  end)
  
  # Functions to apply different action types
  defp apply_action_fn(:create), do: &Ash.create/1
  defp apply_action_fn(:update), do: &Ash.update/1
  defp apply_action_fn(:destroy), do: &Ash.destroy/1
end
```

You can customize the projector name with the `projector_name` option or disable automatic generation with `autogenerate?: false`.

## Router Usage

The generated routers allow dispatching commands to their appropriate handlers:

```elixir
# Dispatch a command through the main router
command = %ECommerce.Commands.RegisterCustomer{id: "123", email: "customer@example.com", name: "John Doe"}
AshCommanded.Router.dispatch(command)
```

## Commanded Application

The `application` section in the DSL allows configuring a Commanded application at the domain level:

```elixir
defmodule ECommerce.Store do
  use Ash.Domain, extensions: [AshCommanded.Commanded.Dsl]

  resources do
    resource ECommerce.Product
    resource ECommerce.Customer
    resource ECommerce.Order
  end

  commanded do
    application do
      otp_app :ecommerce
      event_store Commanded.EventStore.Adapters.EventStore
      include_supervisor? true
    end
  end
end
```

This generates a Commanded application module that:
- Configures the event store and other Commanded settings
- Includes the domain router
- Provides a supervisor for all projectors
- Can be added to your application's supervision tree

## Where are the Process Managers?

Process Managers in the Commanded are responsible for coordinating one or more aggregates. It handles events and dispatches commands in response. This is very business logic specific and would be rather difficult to generate appropriately. It is suggested to write your Process Managers using [Reactor](https://hexdocs.pm/reactor/readme.html) instead.


