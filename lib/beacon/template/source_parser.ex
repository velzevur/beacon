defmodule Beacon.Template.SourceParser do
  @moduledoc """
  Recursive descent parser for Beacon template source.

  Beacon templates are HTML-like markup with `{{ }}` interpolations and
  directive attributes such as `:if`, `:else-if`, `:else`, and `:for`.
  This parser emits the platform-agnostic `Beacon.Template.AST` shape used by
  the runtime renderer.
  """

  alias Beacon.Template.AST
  alias Beacon.Template.ExpressionParser

  @directives ~w(if else-if else for)
  @raw_text_tags ~w(script style textarea title)
  @void_tags ~w(area base br col embed hr img input link meta param source track wbr)

  @type parser :: %{
          source: binary(),
          offset: non_neg_integer(),
          size: non_neg_integer()
        }

  @spec parse(binary()) :: [AST.ast_node()]
  def parse(template) when is_binary(template) do
    parser = %{source: template, offset: 0, size: byte_size(template)}
    {nodes, parser} = parse_nodes(parser, nil)

    if eof?(parser) do
      nodes
      |> trim_boundary_whitespace()
      |> link_else_chains()
    else
      raise_error(parser, "unexpected trailing input")
    end
  end

  defp parse_nodes(parser, closing_tag) do
    parse_nodes(parser, closing_tag, [])
  end

  defp parse_nodes(parser, nil, acc) do
    cond do
      eof?(parser) ->
        {Enum.reverse(acc), parser}

      starts_with?(parser, "</") ->
        raise_error(parser, "unexpected closing tag #{inspect(peek_closing_tag(parser))}")

      true ->
        {nodes, parser} = parse_node(parser)
        parse_nodes(parser, nil, prepend_all(nodes, acc))
    end
  end

  defp parse_nodes(parser, closing_tag, acc) do
    cond do
      eof?(parser) ->
        raise_error(parser, "missing closing tag </#{closing_tag}>")

      starts_with?(parser, "</") ->
        {tag, parser} = parse_closing_tag(parser)

        if same_tag?(tag, closing_tag) do
          {Enum.reverse(acc), parser}
        else
          raise_error(parser, "expected closing tag </#{closing_tag}>, got </#{tag}>")
        end

      true ->
        {nodes, parser} = parse_node(parser)
        parse_nodes(parser, closing_tag, prepend_all(nodes, acc))
    end
  end

  defp parse_node(parser) do
    cond do
      starts_with?(parser, "<!--") ->
        {[], consume_comment(parser)}

      starts_with?(parser, "<!") ->
        {[], consume_declaration(parser)}

      starts_with?(parser, "<?") ->
        {[], consume_processing_instruction(parser)}

      starts_with?(parser, "<") ->
        parse_element(parser)

      true ->
        parse_text(parser)
    end
  end

  defp parse_element(parser) do
    parser = advance(parser, 1)
    {tag, parser} = parse_tag_name(parser)
    {attrs, parser, self_closing?} = parse_attrs(parser, [])

    cond do
      self_closing? or tag in @void_tags ->
        {[build_node(tag, attrs, [])], parser}

      tag in @raw_text_tags ->
        {text, parser} = parse_raw_text(parser, tag)
        {[build_node(tag, attrs, if(text == "", do: [], else: [AST.text(text)]))], parser}

      true ->
        {children, parser} = parse_nodes(parser, tag)
        children = trim_boundary_whitespace(children)
        {[build_node(tag, attrs, children)], parser}
    end
  end

  defp parse_tag_name(parser) do
    start = parser.offset
    parser = advance_while(parser, &tag_name_char?/1)

    if parser.offset == start do
      raise_error(parser, "expected tag name")
    else
      {slice(parser.source, start, parser.offset), parser}
    end
  end

  defp parse_closing_tag(parser) do
    parser = advance(parser, 2)
    parser = skip_whitespace(parser)
    {tag, parser} = parse_tag_name(parser)
    parser = skip_whitespace(parser)
    parser = expect(parser, ">")
    {tag, parser}
  end

  defp parse_attrs(parser, attrs) do
    parser = skip_whitespace(parser)

    cond do
      starts_with?(parser, "/>") ->
        {Map.new(Enum.reverse(attrs)), advance(parser, 2), true}

      starts_with?(parser, ">") ->
        {Map.new(Enum.reverse(attrs)), advance(parser, 1), false}

      eof?(parser) ->
        raise_error(parser, "unterminated start tag")

      true ->
        {name, parser} = parse_attr_name(parser)
        parser = skip_whitespace(parser)
        {value, parser} = parse_optional_attr_value(parser)
        parse_attrs(parser, [{name, value} | attrs])
    end
  end

  defp parse_attr_name(parser) do
    start = parser.offset
    parser = advance_while(parser, &attr_name_char?/1)

    if parser.offset == start do
      raise_error(parser, "expected attribute name")
    else
      {slice(parser.source, start, parser.offset), parser}
    end
  end

  defp parse_optional_attr_value(parser) do
    if starts_with?(parser, "=") do
      parser
      |> advance(1)
      |> skip_whitespace()
      |> parse_attr_value()
    else
      {"", parser}
    end
  end

  defp parse_attr_value(parser) do
    cond do
      starts_with?(parser, "\"") ->
        parse_quoted_attr_value(parser, "\"")

      starts_with?(parser, "'") ->
        parse_quoted_attr_value(parser, "'")

      starts_with?(parser, "{") ->
        parse_braced_attr_value(parser)

      true ->
        parse_unquoted_attr_value(parser)
    end
  end

  defp parse_quoted_attr_value(parser, quote) do
    parser = advance(parser, 1)
    start = parser.offset

    case find(parser, quote) do
      nil ->
        raise_error(parser, "unterminated quoted attribute")

      finish ->
        value = slice(parser.source, start, finish)
        {value, %{parser | offset: finish + byte_size(quote)}}
    end
  end

  defp parse_braced_attr_value(parser) do
    parser = advance(parser, 1)
    start = parser.offset
    {finish, parser} = consume_balanced_braces(parser, 1)
    {slice(parser.source, start, finish), parser}
  end

  defp parse_unquoted_attr_value(parser) do
    start = parser.offset
    parser = advance_while(parser, &unquoted_attr_value_char?/1)

    if parser.offset == start do
      raise_error(parser, "expected attribute value")
    else
      {slice(parser.source, start, parser.offset), parser}
    end
  end

  defp consume_balanced_braces(parser, 0), do: {parser.offset - 1, parser}

  defp consume_balanced_braces(parser, depth) do
    cond do
      eof?(parser) ->
        raise_error(parser, "unterminated braced attribute")

      starts_with?(parser, "{") ->
        parser |> advance(1) |> consume_balanced_braces(depth + 1)

      starts_with?(parser, "}") ->
        parser |> advance(1) |> consume_balanced_braces(depth - 1)

      starts_with?(parser, "\"") ->
        parser |> consume_string("\"") |> consume_balanced_braces(depth)

      starts_with?(parser, "'") ->
        parser |> consume_string("'") |> consume_balanced_braces(depth)

      true ->
        parser |> advance(1) |> consume_balanced_braces(depth)
    end
  end

  defp consume_string(parser, quote) do
    parser = advance(parser, 1)

    cond do
      eof?(parser) ->
        raise_error(parser, "unterminated string in braced attribute")

      starts_with?(parser, "\\") ->
        parser |> advance(2) |> consume_string(quote)

      starts_with?(parser, quote) ->
        advance(parser, 1)

      true ->
        parser |> advance(1) |> consume_string(quote)
    end
  end

  defp parse_raw_text(parser, tag) do
    closing = "</#{tag}>"

    case find(parser, closing) do
      nil ->
        raise_error(parser, "missing closing tag </#{tag}>")

      finish ->
        text = slice(parser.source, parser.offset, finish)
        {_, parser} = parse_closing_tag(%{parser | offset: finish})
        {text, parser}
    end
  end

  defp parse_text(parser) do
    start = parser.offset

    parser =
      case find(parser, "<") do
        nil -> %{parser | offset: parser.size}
        offset -> %{parser | offset: offset}
      end

    text = slice(parser.source, start, parser.offset)
    {parse_text_with_interpolations(text), parser}
  end

  defp parse_text_with_interpolations(text) do
    parse_text_with_interpolations(text, [])
  end

  defp parse_text_with_interpolations("", acc), do: Enum.reverse(acc)

  defp parse_text_with_interpolations(text, acc) do
    case :binary.match(text, "{{") do
      :nomatch ->
        Enum.reverse(prepend_text(text, acc))

      {start, 2} ->
        before = binary_part(text, 0, start)
        rest_start = start + 2
        rest = binary_part(text, rest_start, byte_size(text) - rest_start)

        case :binary.match(rest, "}}") do
          :nomatch ->
            raise Beacon.Template.ParseError, "unterminated interpolation"

          {finish, 2} ->
            expr = binary_part(rest, 0, finish)
            after_start = finish + 2
            after_text = binary_part(rest, after_start, byte_size(rest) - after_start)
            parsed = ExpressionParser.parse_interpolation(String.trim(expr))
            expression = %{type: :expression, path: parsed.path, filters: parsed.filters}

            after_text
            |> parse_text_with_interpolations([expression | prepend_text(before, acc)])
        end
    end
  end

  defp build_node("template", attrs, children) do
    children = Enum.reject(children, &whitespace_text?/1)

    cond do
      Map.has_key?(attrs, ":if") ->
        condition = ExpressionParser.parse_condition(attrs[":if"])
        AST.conditional(condition, [AST.fragment(children)])

      Map.has_key?(attrs, ":for") ->
        {iterator, iterable} = ExpressionParser.parse_for(attrs[":for"])
        AST.loop(iterator, iterable, [AST.fragment(children)])

      true ->
        AST.fragment(children)
    end
  end

  defp build_node(tag, attrs, children) do
    cond do
      Map.has_key?(attrs, ":if") ->
        condition = ExpressionParser.parse_condition(attrs[":if"])
        element = build_element(tag, Map.drop(attrs, [":if"]), children)
        AST.conditional(condition, [element])

      Map.has_key?(attrs, ":else-if") ->
        condition = ExpressionParser.parse_condition(attrs[":else-if"])
        element = build_element(tag, Map.drop(attrs, [":else-if"]), children)
        {:pending_else_if, condition, [element]}

      Map.has_key?(attrs, ":else") ->
        element = build_element(tag, Map.drop(attrs, [":else"]), children)
        {:pending_else, [element]}

      Map.has_key?(attrs, ":for") ->
        {iterator, iterable} = ExpressionParser.parse_for(attrs[":for"])
        element = build_element(tag, Map.drop(attrs, [":for"]), children)
        AST.loop(iterator, iterable, [element])

      true ->
        build_element(tag, attrs, children)
    end
  end

  defp build_element(tag, attrs, children) do
    {static_attrs, dynamic_attrs, events} = classify_attrs(attrs)

    parsed_dynamic =
      Map.new(dynamic_attrs, fn {name, expr} ->
        {name, ExpressionParser.parse_interpolation(expr)}
      end)

    all_attrs =
      Map.merge(static_attrs, parsed_dynamic, fn
        "class", static_val, dynamic_expr when is_binary(static_val) ->
          %{type: :class_merge, static: static_val, dynamic: dynamic_expr}

        _key, _static, dynamic ->
          dynamic
      end)

    AST.element(tag, all_attrs, events, children)
  end

  defp classify_attrs(attrs) do
    Enum.reduce(attrs, {%{}, %{}, %{}}, fn
      {":" <> directive, _value}, acc when directive in @directives ->
        acc

      {":" <> prop_name, value}, {static, dynamic, events} ->
        {static, Map.put(dynamic, prop_name, value), events}

      {"@" <> event_name, handler}, {static, dynamic, events} ->
        {static, dynamic, Map.put(events, event_name, handler)}

      {name, value}, {static, dynamic, events} ->
        {Map.put(static, name, value), dynamic, events}
    end)
  end

  defp link_else_chains(nodes) do
    nodes
    |> Enum.reduce([], fn
      {:pending_else_if, condition, then_nodes}, acc ->
        {_whitespace, acc} = pop_leading_whitespace(acc)

        case acc do
          [%{type: :conditional} = prev | rest] ->
            [append_else_if(prev, condition, then_nodes) | rest]

          _ ->
            raise Beacon.Template.ParseError, ":else-if without preceding :if"
        end

      {:pending_else, else_nodes}, acc ->
        {_whitespace, acc} = pop_leading_whitespace(acc)

        case acc do
          [%{type: :conditional} = prev | rest] ->
            [append_else(prev, else_nodes) | rest]

          _ ->
            raise Beacon.Template.ParseError, ":else without preceding :if"
        end

      node, acc ->
        [link_children(node) | acc]
    end)
    |> Enum.reverse()
  end

  defp append_else_if(conditional, condition, then_nodes) do
    if conditional.else == [] do
      %{conditional | else: [AST.conditional(condition, then_nodes)]}
    else
      [last_else | _] = conditional.else

      if last_else.type == :conditional do
        %{conditional | else: [append_else_if(last_else, condition, then_nodes)]}
      else
        raise Beacon.Template.ParseError, ":else-if after :else"
      end
    end
  end

  defp append_else(conditional, else_nodes) do
    if conditional.else == [] do
      %{conditional | else: else_nodes}
    else
      [last_else | _] = conditional.else

      if last_else.type == :conditional do
        %{conditional | else: [append_else(last_else, else_nodes)]}
      else
        raise Beacon.Template.ParseError, "duplicate :else"
      end
    end
  end

  defp link_children(%{children: children} = node) when is_list(children) do
    %{node | children: link_else_chains(children)}
  end

  defp link_children(%{then: then_nodes, else: else_nodes} = node) do
    %{node | then: link_else_chains(then_nodes), else: link_else_chains(else_nodes)}
  end

  defp link_children(node), do: node

  defp pop_leading_whitespace(nodes) do
    Enum.split_while(nodes, &whitespace_text?/1)
  end

  defp trim_boundary_whitespace(nodes) do
    nodes
    |> drop_leading_whitespace()
    |> Enum.reverse()
    |> drop_leading_whitespace()
    |> Enum.reverse()
  end

  defp drop_leading_whitespace(nodes), do: Enum.drop_while(nodes, &whitespace_text?/1)

  defp whitespace_text?(%{type: :text, value: value}), do: String.trim(value) == ""
  defp whitespace_text?(_), do: false

  defp consume_comment(parser) do
    parser = advance(parser, 4)

    case find(parser, "-->") do
      nil -> raise_error(parser, "unterminated comment")
      finish -> %{parser | offset: finish + 3}
    end
  end

  defp consume_declaration(parser) do
    case find(parser, ">") do
      nil -> raise_error(parser, "unterminated declaration")
      finish -> %{parser | offset: finish + 1}
    end
  end

  defp consume_processing_instruction(parser) do
    parser = advance(parser, 2)

    case find(parser, "?>") do
      nil -> raise_error(parser, "unterminated processing instruction")
      finish -> %{parser | offset: finish + 2}
    end
  end

  defp expect(parser, token) do
    if starts_with?(parser, token) do
      advance(parser, byte_size(token))
    else
      raise_error(parser, "expected #{inspect(token)}")
    end
  end

  defp peek_closing_tag(parser) do
    parser = parser |> advance(2) |> skip_whitespace()
    start = parser.offset
    parser = advance_while(parser, &tag_name_char?/1)

    if parser.offset == start do
      ""
    else
      slice(parser.source, start, parser.offset)
    end
  end

  defp prepend_text("", acc), do: acc
  defp prepend_text(text, acc), do: [AST.text(text) | acc]

  defp prepend_all(nodes, acc), do: Enum.reduce(nodes, acc, &[&1 | &2])

  defp tag_name_char?(char), do: not whitespace?(char) and char not in [?/, ?>]
  defp attr_name_char?(char), do: not whitespace?(char) and char not in [?=, ?/, ?>]
  defp unquoted_attr_value_char?(char), do: not whitespace?(char) and char != ?>
  defp whitespace?(char), do: char in [?\s, ?\t, ?\n, ?\r, ?\f]

  defp skip_whitespace(parser), do: advance_while(parser, &whitespace?/1)

  defp advance_while(parser, fun) do
    if eof?(parser) do
      parser
    else
      char = :binary.at(parser.source, parser.offset)

      if fun.(char) do
        parser |> advance(1) |> advance_while(fun)
      else
        parser
      end
    end
  end

  defp advance(parser, bytes), do: %{parser | offset: min(parser.offset + bytes, parser.size)}
  defp eof?(parser), do: parser.offset >= parser.size

  defp starts_with?(parser, token) do
    remaining = parser.size - parser.offset
    size = byte_size(token)
    remaining >= size and binary_part(parser.source, parser.offset, size) == token
  end

  defp find(parser, token) do
    remaining = parser.size - parser.offset

    case :binary.match(parser.source, token, scope: {parser.offset, remaining}) do
      :nomatch -> nil
      {offset, _length} -> offset
    end
  end

  defp slice(source, start, finish), do: binary_part(source, start, finish - start)

  defp same_tag?(left, right), do: String.downcase(left) == String.downcase(right)

  defp raise_error(parser, message) do
    {line, column} = line_column(parser.source, parser.offset)
    raise Beacon.Template.ParseError, "#{message} at line #{line}, column #{column}"
  end

  defp line_column(source, offset) do
    prefix = binary_part(source, 0, min(offset, byte_size(source)))
    lines = String.split(prefix, "\n")
    {length(lines), String.length(List.last(lines) || "") + 1}
  end
end
