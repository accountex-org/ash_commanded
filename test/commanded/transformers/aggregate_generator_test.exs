defmodule AshCommanded.Commanded.Transformers.AggregateGeneratorTest do
  use ExUnit.Case, async: true

  alias AshCommanded.Commanded.Command
  alias AshCommanded.Commanded.Event
  alias AshCommanded.Commanded.Transformers.GenerateAggregateModule

  describe "aggregate module generation helpers" do
    setup do
      {:ok,
       %{
         command_modules: %{register_user: MyApp.Commands.RegisterUser},
         event_modules: %{user_registered: MyApp.Events.UserRegistered}
       }}
    end

    test "builds correct module names" do
      # Test module naming
      module_name =
        invoke_private(
          GenerateAggregateModule,
          :build_aggregate_module,
          ["User", MyApp.Accounts]
        )

      assert module_name == MyApp.Accounts.UserAggregate
    end

    test "builds correct module AST", %{
      command_modules: command_modules,
      event_modules: event_modules
    } do
      # Set up test data
      attribute_names = [:id, :email, :name, :status]

      command = %Command{
        name: :register_user,
        fields: [:id, :email, :name],
        identity_field: :id
      }

      event = %Event{
        name: :user_registered,
        fields: [:id, :email, :name]
      }

      # Generate the AST
      ast =
        invoke_private(
          GenerateAggregateModule,
          :build_aggregate_module_ast,
          [
            "User",
            attribute_names,
            [command],
            [event],
            command_modules,
            event_modules
          ]
        )

      # The AST should be a block with expected elements
      ast_string = Macro.to_string(ast)

      # Check for expected components
      [
        "@moduledoc",
        "defstruct",

        # Check for defstruct keyword and struct fields
        "defstruct",

        # Test if struct looks like it contains our fields
        # Due to Macro.to_string formatting, we can't precisely check field format
        # But we can still check for presence of field keywords
        "id:",
        "email:",
        "name:",

        # Check for execute function
        "def execute",
        "RegisterUser",

        # Check for apply function
        "def apply",
        "UserRegistered"
      ]
      |> Enum.each(fn expected ->
        assert String.contains?(ast_string, expected)
      end)
    end

    test "handles commands with no matching events" do
      # Set up test data with a command that has no matching event
      attribute_names = [:id, :email]

      command = %Command{
        name: :update_email,
        fields: [:id, :email],
        identity_field: :id
      }

      # No matching event for update_email
      event = %Event{
        name: :user_registered,
        fields: [:id, :email, :name]
      }

      command_modules = %{
        update_email: MyApp.Commands.UpdateEmail
      }

      event_modules = %{
        user_registered: MyApp.Events.UserRegistered
      }

      # Generate the AST
      ast =
        invoke_private(
          GenerateAggregateModule,
          :build_aggregate_module_ast,
          [
            "User",
            attribute_names,
            [command],
            [event],
            command_modules,
            event_modules
          ]
        )

      # Convert to string for easier inspection
      ast_string = Macro.to_string(ast)

      # Check that it includes warning about not implemented command
      assert String.contains?(ast_string, "Command not implemented")
      assert String.contains?(ast_string, "Error.aggregate_error")
      assert String.contains?(ast_string, "Logger.warning")
    end

    test "includes default snapshot functions when dsl_state is nil" do
      # When no application config is present (dsl_state nil), we get default snapshot behaviour
      attribute_names = [:id, :email]
      command = %Command{name: :register_user, fields: [:id, :email], identity_field: :id}
      event = %Event{name: :user_registered, fields: [:id, :email]}
      command_modules = %{register_user: MyApp.Commands.RegisterUser}
      event_modules = %{user_registered: MyApp.Events.UserRegistered}

      ast =
        invoke_private(
          GenerateAggregateModule,
          :build_aggregate_module_ast,
          ["User", attribute_names, [command], [event], command_modules, event_modules, nil]
        )

      ast_string = Macro.to_string(ast)

      # Default snapshot helpers (from application section defaults)
      assert String.contains?(ast_string, "def snapshot_version"), "expected snapshot_version/0"

      assert String.contains?(ast_string, "def snapshot_threshold"),
             "expected snapshot_threshold/0"

      assert String.contains?(ast_string, "def should_snapshot?"), "expected should_snapshot?/1"
      # Default values when app_config is nil (100, 1)
      assert ast_string =~ ~r/snapshot_threshold.*\b100\b|100.*snapshot_threshold/
      assert ast_string =~ ~r/snapshot_version.*\b1\b|1.*snapshot_version/
      # Snapshotting disabled by default → no create_snapshot / maybe_snapshot
      refute String.contains?(ast_string, "def create_snapshot("),
             "expected no create_snapshot when snapshotting is disabled"

      # No-op snapshot_state_if_needed/1 is always generated so apply/2 compiles in consuming apps
      assert String.contains?(ast_string, "def snapshot_state_if_needed("),
             "expected snapshot_state_if_needed/1 to be generated even when snapshotting is disabled"
    end

    test "snapshot functions use application config when dsl_state has application section" do
      # When dsl_state is present, build_aggregate_module_ast calls Dsl.application(dsl_state).
      # Stub Dsl.application to return config so we assert the AST uses it.
      app_config = [
        snapshotting: true,
        snapshot_threshold: 50,
        snapshot_version: 2
      ]

      :meck.new(AshCommanded.Commanded.Dsl, [:passthrough])
      :meck.expect(AshCommanded.Commanded.Dsl, :application, fn _ -> app_config end)

      attribute_names = [:id, :email]
      command = %Command{name: :register_user, fields: [:id, :email], identity_field: :id}
      event = %Event{name: :user_registered, fields: [:id, :email]}
      command_modules = %{register_user: MyApp.Commands.RegisterUser}
      event_modules = %{user_registered: MyApp.Events.UserRegistered}
      # non-nil so Dsl.application/1 is called
      dsl_state = %{}

      ast =
        invoke_private(
          GenerateAggregateModule,
          :build_aggregate_module_ast,
          [
            "User",
            attribute_names,
            [command],
            [event],
            command_modules,
            event_modules,
            dsl_state
          ]
        )

      :meck.unload(AshCommanded.Commanded.Dsl)

      ast_string = Macro.to_string(ast)

      assert ast_string =~ ~r/\b50\b/, "expected snapshot_threshold 50 in generated code"
      assert ast_string =~ ~r/\b2\b/, "expected snapshot_version 2 in generated code"

      assert String.contains?(ast_string, "create_snapshot"),
             "expected create_snapshot when snapshotting is enabled"

      assert String.contains?(ast_string, "snapshot_state_if_needed"),
             "expected snapshot_state_if_needed when snapshotting is enabled"
    end

    test "always generates snapshot_state_if_needed/1 so apply/2 compiles in consuming apps" do
      # When snapshotting is disabled (dsl_state nil), apply/2 still calls snapshot_state_if_needed/1.
      # The aggregate module must define that function (as a no-op) or compilation fails in consuming apps.
      attribute_names = [:id, :email]
      command = %Command{name: :register_user, fields: [:id, :email], identity_field: :id}
      event = %Event{name: :user_registered, fields: [:id, :email]}
      command_modules = %{register_user: MyApp.Commands.RegisterUser}
      event_modules = %{user_registered: MyApp.Events.UserRegistered}

      ast_with_nil_dsl =
        invoke_private(
          GenerateAggregateModule,
          :build_aggregate_module_ast,
          ["User", attribute_names, [command], [event], command_modules, event_modules, nil]
        )

      ast_string_nil = Macro.to_string(ast_with_nil_dsl)

      assert String.contains?(ast_string_nil, "def snapshot_state_if_needed("),
             "snapshot_state_if_needed/1 must be generated when dsl_state is nil (snapshotting disabled)"

      # When snapshotting is enabled, the full implementation is generated
      app_config = [snapshotting: true, snapshot_threshold: 50, snapshot_version: 2]
      :meck.new(AshCommanded.Commanded.Dsl, [:passthrough])
      :meck.expect(AshCommanded.Commanded.Dsl, :application, fn _ -> app_config end)
      dsl_state = %{}

      ast_with_app_config =
        invoke_private(
          GenerateAggregateModule,
          :build_aggregate_module_ast,
          [
            "User",
            attribute_names,
            [command],
            [event],
            command_modules,
            event_modules,
            dsl_state
          ]
        )

      :meck.unload(AshCommanded.Commanded.Dsl)
      ast_string_enabled = Macro.to_string(ast_with_app_config)

      assert String.contains?(ast_string_enabled, "def snapshot_state_if_needed("),
             "snapshot_state_if_needed/1 must be generated when snapshotting is enabled"
    end
  end

  # Helper to invoke private functions for testing
  defp invoke_private(module, function, args) do
    apply(module, function, args)
  catch
    :error, :undef -> {:error, "Private function #{function} not accessible"}
  end
end
