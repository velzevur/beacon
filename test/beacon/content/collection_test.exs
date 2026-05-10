defmodule Beacon.Content.CollectionTest do
  use ExUnit.Case, async: true

  alias Beacon.Content.Collection

  describe "changeset/2" do
    test "valid with name, slug, and mode" do
      attrs = %{name: "Blog Post", slug: "blog-post", mode: "managed"}
      cs = Collection.changeset(%Collection{}, attrs)
      assert cs.valid?
    end

    test "requires name" do
      cs = Collection.changeset(%Collection{}, %{slug: "test", mode: "managed"})
      refute cs.valid?
    end

    test "requires slug" do
      cs = Collection.changeset(%Collection{}, %{name: "Test", mode: "managed"})
      refute cs.valid?
    end

    test "requires mode" do
      cs = Collection.changeset(%Collection{}, %{name: "Test", slug: "test", mode: nil})
      refute cs.valid?
    end

    test "validates mode inclusion" do
      cs = Collection.changeset(%Collection{}, %{name: "Test", slug: "test", mode: "bogus"})
      refute cs.valid?

      cs = Collection.changeset(%Collection{}, %{name: "Test", slug: "test", mode: "template"})
      assert cs.valid?
    end

    test "validates slug format — lowercase with hyphens" do
      cs = Collection.changeset(%Collection{}, %{name: "Test", slug: "Valid-Slug", mode: "managed"})
      refute cs.valid?

      cs = Collection.changeset(%Collection{}, %{name: "Test", slug: "valid-slug", mode: "managed"})
      assert cs.valid?
    end

    test "validates slug format — no spaces" do
      cs = Collection.changeset(%Collection{}, %{name: "Test", slug: "has space", mode: "managed"})
      refute cs.valid?
    end

    test "validates fields — rejects non-maps" do
      cs = Collection.changeset(%Collection{}, %{name: "T", slug: "t", mode: "managed", fields: ["not a map"]})
      refute cs.valid?
    end

    test "validates fields — requires name on each item" do
      cs = Collection.changeset(%Collection{}, %{name: "T", slug: "t", mode: "managed", fields: [%{"type" => "string"}]})
      refute cs.valid?
    end

    test "validates fields — requires valid type" do
      cs = Collection.changeset(%Collection{}, %{name: "T", slug: "t", mode: "managed", fields: [%{"name" => "x", "type" => "invalid"}]})
      refute cs.valid?
    end

    test "validates fields — rejects duplicate names" do
      defs = [%{"name" => "title", "type" => "string"}, %{"name" => "title", "type" => "text"}]
      cs = Collection.changeset(%Collection{}, %{name: "T", slug: "t", mode: "managed", fields: defs})
      refute cs.valid?
    end

    test "valid fields with proper structure" do
      defs = [
        %{"name" => "author", "type" => "string", "required" => true, "label" => "Author"},
        %{"name" => "date", "type" => "datetime"}
      ]
      cs = Collection.changeset(%Collection{}, %{name: "Blog", slug: "blog", mode: "managed", fields: defs})
      assert cs.valid?
    end

    test "site can be nil for global collections" do
      cs = Collection.changeset(%Collection{}, %{name: "Global", slug: "global", mode: "managed", site: nil})
      assert cs.valid?
    end
  end
end
