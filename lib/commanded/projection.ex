defmodule AshCommanded.Commanded.Projection do
  @moduledoc """
  Represents a projection in the Commanded DSL.
  
  Projections define how events affect the resource state, transforming events into resource updates.
  """
  
  @type t :: %__MODULE__{
    name: atom(),
    event_name: atom(),
    action: atom(),
    changes: map() | function(),
    autogenerate?: boolean()
  }
  
  defstruct [
    :name,
    :event_name,
    :action,
    :changes,
    autogenerate?: true
  ]
end