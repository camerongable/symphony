defmodule SymphonyElixir.CodexOutputSchemaTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Codex.OutputSchema
  alias SymphonyElixir.Factory.StageSchemas

  test "provider array and required-field restrictions preserve the canonical no-edit contract" do
    canonical = %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["changed_paths", "commit_message"],
      "properties" => %{
        "changed_paths" => %{"type" => "array", "items" => %{"type" => "string"}, "enum" => [[]]},
        "commit_message" => %{"type" => ["string", "null"], "enum" => [nil]},
        "summary" => %{"type" => "string"}
      }
    }

    wire = OutputSchema.for_provider(canonical)
    assert wire["required"] == ["changed_paths", "commit_message", "summary"]
    assert wire["properties"]["changed_paths"] == %{"type" => "array", "items" => %{"type" => "string"}, "maxItems" => 0}
    assert canonical["properties"]["changed_paths"]["enum"] == [[]]
    assert :ok = StageSchemas.validate(%{"changed_paths" => [], "commit_message" => nil, "summary" => ""}, canonical)
    assert {:error, _} = StageSchemas.validate(%{"changed_paths" => ["edit.go"], "commit_message" => nil}, canonical)
    assert OutputSchema.for_provider(wire) == wire
  end

  test "nested objects and compositions are normalized without rewriting unrelated constraints" do
    child = %{"type" => "object", "required" => [], "properties" => %{"value" => %{"type" => "integer", "enum" => [1]}}}
    assert OutputSchema.for_provider(%{"items" => child})["items"]["required"] == ["value"]
    assert hd(OutputSchema.for_provider(%{"anyOf" => [child]})["anyOf"])["required"] == ["value"]
    assert OutputSchema.for_provider(%{"type" => "string", "enum" => ["COMPLETE", "BLOCKED"]}) == %{"type" => "string", "enum" => ["COMPLETE", "BLOCKED"]}
    assert is_nil(OutputSchema.for_provider(nil))
  end

  test "schema-looking literal values are not interpreted as schema nodes" do
    literal = %{"type" => "object", "properties" => %{"value" => %{"type" => "string"}}}
    canonical = %{"type" => "object", "properties" => %{}, "enum" => [literal], "default" => literal, "const" => literal, "examples" => [literal]}
    wire = OutputSchema.for_provider(canonical)
    assert Map.take(wire, ~w(enum default const examples)) == Map.take(canonical, ~w(enum default const examples))
    assert wire["required"] == []
  end

  test "exclusive and negative composition retain whole-schema semantics including referenced definitions" do
    a = %{"type" => "string"}
    branch = %{"type" => "object", "additionalProperties" => false, "properties" => %{"a" => a, "b" => a}, "required" => []}
    other = %{branch | "properties" => %{"a" => a}}

    schemas = [
      %{"oneOf" => [branch, other]},
      %{"not" => branch},
      %{"not" => %{"$ref" => "#/$defs/branch"}, "$defs" => %{"branch" => branch}},
      %{"type" => "object", "properties" => %{"nested" => %{"oneOf" => [branch, other]}}},
      %{"definitions" => %{"branch" => branch}, "patternProperties" => %{"^x$" => %{"not" => %{"$ref" => "#/definitions/branch"}}}},
      %{"definitions" => %{"branch" => branch}, "dependentSchemas" => %{"x" => %{"not" => %{"$ref" => "#/definitions/branch"}}}},
      %{"definitions" => %{"branch" => branch}, "items" => [%{"not" => %{"$ref" => "#/definitions/branch"}}]},
      %{"$ref" => "#/default", "default" => %{"not" => branch}, "$defs" => %{"branch" => branch}}
    ]

    for schema <- schemas, do: assert(OutputSchema.for_provider(schema) == schema)
  end

  test "boolean schema nodes remain unchanged" do
    schema = %{"type" => "object", "properties" => %{"anything" => true, "nothing" => false}, "$defs" => %{"none" => false}}
    wire = OutputSchema.for_provider(schema)
    assert wire["properties"] == schema["properties"] and wire["$defs"] == schema["$defs"]
    assert OutputSchema.for_provider(false) == false
  end
end
