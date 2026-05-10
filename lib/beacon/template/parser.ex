defmodule Beacon.Template.Parser do
  @moduledoc """
  Parses Beacon template syntax into a platform-agnostic JSON AST.

  Templates are HTML with `{{ }}` interpolation and `:directive` attributes:

      <h1>{{ post.title }}</h1>
      <div :if="post.featured" class="badge">Featured</div>
      <ul :for="item in items"><li>{{ item.name }}</li></ul>

  The parser walks Beacon source directly and emits the runtime AST.
  """

  alias Beacon.Template.AST

  @doc """
  Parse a Beacon template string into a list of AST nodes.
  """
  @spec parse(binary()) :: [AST.ast_node()]
  def parse(template) when is_binary(template) do
    Beacon.Template.SourceParser.parse(template)
  end
end
