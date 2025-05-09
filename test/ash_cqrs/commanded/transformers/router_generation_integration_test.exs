defmodule AshCommanded.Commanded.Transformers.RouterGenerationIntegrationTest do
  use ExUnit.Case, async: true

  defmodule AppRouter do
    # This will be auto-generated by the transformers,
    # but we define a test module here to isolate the test
    use Commanded.Commands.Router
  end

  defmodule IntegrationResource do
    use Ash.Resource,
      extensions: [AshCommanded.Commanded.Dsl]

    attributes do
      uuid_primary_key :id
      attribute :name, :string
      attribute :status, :string
    end

    identities do
      identity :unique_id, [:id]
    end

    commanded do
      commands do
        command :create_resource do
          fields([:id, :name])
          identity_field(:id)
        end

        command :update_status do
          fields([:id, :status])
        end
      end

      events do
        event :resource_created do
          fields([:id, :name])
        end

        event :status_updated do
          fields([:id, :status])
        end
      end

      projections do
        projection :resource_created do
          changes(%{status: "active"})
        end

        projection :status_updated do
          action(:update_by_id)
          changes(&Map.take(&1, [:status]))
        end
      end
    end
  end

  defmodule IntegrationDomain do
    use Ash.Domain

    resources do
      resource IntegrationResource
    end
  end

  # These tests validate that the correct module structure has been created
  # and that the command paths are properly wired up

  test "router modules are properly generated" do
    # Domain router should exist
    domain_router = Module.concat([IntegrationDomain, "Router"])
    assert Code.ensure_loaded?(domain_router)
    
    # Main router should exist
    main_router = Module.concat(["AshCommanded", "Router"])
    assert Code.ensure_loaded?(main_router)
    
    # Command modules should exist
    create_command = Module.concat(["Commands", "CreateResource"])
    update_command = Module.concat(["Commands", "UpdateStatus"])
    assert Code.ensure_loaded?(create_command)
    assert Code.ensure_loaded?(update_command)
    
    # Event modules should exist
    created_event = Module.concat(["Events", "ResourceCreated"])
    updated_event = Module.concat(["Events", "StatusUpdated"])
    assert Code.ensure_loaded?(created_event)
    assert Code.ensure_loaded?(updated_event)
    
    # Aggregate module should exist
    aggregate = Module.concat(["IntegrationResourceAggregate"])
    assert Code.ensure_loaded?(aggregate)
  end

  test "domain router implements Commanded.Commands.Router behavior" do
    domain_router = Module.concat([IntegrationDomain, "Router"])
    assert Spark.implements_behaviour?(domain_router, Commanded.Commands.Router)
  end

  test "main router implements Commanded.Commands.Router behavior" do
    main_router = Module.concat(["AshCommanded", "Router"])
    assert Spark.implements_behaviour?(main_router, Commanded.Commands.Router)
  end
end