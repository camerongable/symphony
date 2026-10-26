defmodule SymphonyElixir.Codex.OutputSchema do
  @moduledoc "Provider wire restrictions without changing the controller's canonical output contract."

  @supported_keys ~w($schema $id $anchor $comment $defs definitions title description default examples const
                     type properties required additionalProperties items prefixItems anyOf allOf enum
                     minItems maxItems uniqueItems minLength maxLength pattern format contentEncoding contentMediaType
                     minimum maximum exclusiveMinimum exclusiveMaximum multipleOf minProperties maxProperties
                     readOnly writeOnly deprecated)

  @spec for_provider(map() | boolean() | nil) :: map() | boolean() | nil
  def for_provider(nil), do: nil
  def for_provider(value) when is_boolean(value), do: value

  def for_provider(schema) when is_map(schema) do
    if unsafe_composition?(schema) do
      schema
    else
      schema
      |> schema_positions()
      |> require_properties()
      |> empty_array()
    end
  end

  defp unsafe_composition?(schema) when is_map(schema) do
    Map.keys(schema) -- @supported_keys != [] or is_list(schema["items"]) or
      Enum.any?(child_schemas(schema), &unsafe_composition?/1)
  end

  defp unsafe_composition?(_schema), do: false

  defp child_schemas(schema) do
    maps = for key <- ~w(properties $defs definitions), is_map(schema[key]), value <- Map.values(schema[key]), do: value
    lists = for key <- ~w(anyOf allOf prefixItems), is_list(schema[key]), value <- schema[key], do: value
    maps ++ lists ++ Map.values(Map.take(schema, ~w(items additionalProperties)))
  end

  defp schema_positions(schema) do
    schema = Enum.reduce(~w(properties $defs definitions), schema, &update_schema_map/2)
    schema = Enum.reduce(~w(items additionalProperties), schema, &update_schema/2)
    Enum.reduce(~w(anyOf allOf prefixItems), schema, &update_schema_list/2)
  end

  defp update_schema_map(key, schema) do
    case schema[key] do
      values when is_map(values) -> Map.put(schema, key, Map.new(values, fn {name, value} -> {name, for_provider(value)} end))
      _ -> schema
    end
  end

  defp update_schema(key, schema) do
    if is_map(schema[key]), do: Map.put(schema, key, for_provider(schema[key])), else: schema
  end

  defp update_schema_list(key, schema) do
    if is_list(schema[key]), do: Map.put(schema, key, Enum.map(schema[key], &for_provider/1)), else: schema
  end

  defp require_properties(%{"type" => "object", "properties" => properties} = schema) do
    required = Map.get(schema, "required", [])
    Map.put(schema, "required", required ++ Enum.sort(Map.keys(properties) -- required))
  end

  defp require_properties(schema), do: schema

  defp empty_array(%{"type" => "array", "enum" => [[]]} = schema),
    do: schema |> Map.delete("enum") |> Map.put("maxItems", 0)

  defp empty_array(schema), do: schema
end
