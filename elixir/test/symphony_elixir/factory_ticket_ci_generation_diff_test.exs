defmodule SymphonyElixir.FactoryTicketCiGenerationDiffTest do
  use ExUnit.Case, async: true
  alias SymphonyElixir.Factory.TicketCiGenerationDiff

  test "real Gazelle timestamped creation and moved-package removal retain exact scoped preimages" do
    old = "load(\"rules.bzl\", \"go_library\")\n"

    diff =
      "--- /dev/null\t1970-01-01 00:00:00.000000001 +0000\n+++ moved/BUILD\t1970-01-01 00:00:00.000000001 +0000\n@@ -0,0 +1 @@\n+go_library(name = \"moved\")\n--- pkg/BUILD\t1970-01-01 00:00:00.000000001 +0000\n+++ pkg/BUILD\t1970-01-01 00:00:00.000000001 +0000\n@@ -1 +0,0 @@\n-load(\"rules.bzl\", \"go_library\")\n"

    images = %{"moved/BUILD" => "", "pkg/BUILD" => old}
    paths = ~w(moved/BUILD pkg/BUILD)

    assert {:ok,
            [
              %{path: "moved/BUILD", before: "", after: "go_library(name = \"moved\")\n"},
              %{path: "pkg/BUILD", before: ^old, after: ""}
            ]} =
             TicketCiGenerationDiff.plan_generated(diff, "/fixture", paths, images, ["moved/BUILD"])

    assert {:error, :controller_generation_diff_rejected} =
             TicketCiGenerationDiff.plan_generated(diff, "/fixture", paths, images, [])

    assert {:error, :controller_generation_diff_rejected} =
             TicketCiGenerationDiff.plan_generated(
               String.replace(diff, "moved/BUILD", "other/BUILD"),
               "/fixture",
               paths,
               images,
               ["moved/BUILD"]
             )

    assert {:error, :controller_generation_diff_rejected} =
             TicketCiGenerationDiff.plan_generated(
               String.replace(diff, "/dev/null", "/dev/null/not-a-null-path"),
               "/fixture",
               paths,
               images,
               ["moved/BUILD"]
             )
  end

  test "new ordinary generation creates only its exactly observed absent BUILD path" do
    diff = "--- /dev/null\n+++ pkg/BUILD\n@@ -0,0 +1 @@\n+go_library(name = \"pkg\")\n"

    assert {:ok, [%{path: "pkg/BUILD", before: "", after: "go_library(name = \"pkg\")\n"}]} =
             TicketCiGenerationDiff.plan_generated(diff, "/fixture", ["pkg/BUILD"], %{"pkg/BUILD" => ""}, ["pkg/BUILD"])

    for absent <- [[], ["other/BUILD"]] do
      assert {:error, :controller_generation_diff_rejected} =
               TicketCiGenerationDiff.plan_generated(diff, "/fixture", ["pkg/BUILD"], %{"pkg/BUILD" => ""}, absent)
    end

    assert {:error, :controller_generation_diff_rejected} =
             TicketCiGenerationDiff.plan("gazelle", diff, "/fixture", ["pkg/BUILD"], %{"pkg/BUILD" => ""})

    assert {:error, :controller_generation_diff_rejected} =
             TicketCiGenerationDiff.plan_generated(diff, "/fixture", ["pkg/BUILD"], %{"pkg/BUILD" => "existing"}, [
               "pkg/BUILD"
             ])
  end

  test "verified generator diff proposes exact byte changes only for its fixed generated path" do
    before = "deps = [\n    \"//z\",\n    \"//a\",\n]\n"

    diff =
      "--- pkg/BUILD\t1970-01-01 00:00:00\n+++ pkg/BUILD\t1970-01-01 00:00:00\n@@ -1,4 +1,4 @@\n deps = [\n-    \"//z\",\n     \"//a\",\n+    \"//z\",\n ]\n"

    assert {:ok, [%{path: "pkg/BUILD", before: ^before, after: "deps = [\n    \"//a\",\n    \"//z\",\n]\n"}]} =
             TicketCiGenerationDiff.plan("gazelle", diff, "/fixture/source", ["pkg/BUILD"], %{"pkg/BUILD" => before})

    assert {:ok, []} =
             TicketCiGenerationDiff.plan("gazelle", "", "/fixture/source", ["pkg/BUILD"], %{"pkg/BUILD" => before})

    assert {:error, :controller_generation_diff_rejected} =
             TicketCiGenerationDiff.plan("gazelle", diff, "/fixture/source", ["other/BUILD"], %{"pkg/BUILD" => before})

    assert {:error, :controller_generation_diff_rejected} =
             TicketCiGenerationDiff.plan("gazelle", diff, "/fixture/source", ["pkg/BUILD"], %{
               "pkg/BUILD" => "changed\n"
             })
  end

  test "gofmt absolute headers preserve exact preimage bytes" do
    before = "package p\nvar x=1\n"

    diff =
      "diff /fixture/source/p.go.orig /fixture/source/p.go\n--- /fixture/source/p.go.orig\n+++ /fixture/source/p.go\n@@ -1,2 +1,2 @@\n package p\n-var x=1\n+var x = 1\n"

    assert {:ok, [%{path: "p.go", before: ^before, after: "package p\nvar x = 1\n"}]} =
             TicketCiGenerationDiff.plan("gofmt", diff, "/fixture/source", ["p.go"], %{"p.go" => before})
  end

  test "unsupported, ambiguous and out-of-scope diffs reject the entire proposal" do
    before = "a\nb\n"
    diff = "--- pkg/BUILD\n+++ pkg/BUILD\n@@ -1,2 +1,2 @@\n a\n-b\n+c\n"

    for malformed <- [
          diff <> diff,
          String.replace(diff, "pkg/BUILD", "../pkg/BUILD"),
          String.replace(diff, "pkg/BUILD", "-unsafe/BUILD"),
          String.replace(diff, "pkg/BUILD", "/outside/pkg/BUILD"),
          String.replace(diff, "pkg/BUILD", "\"pkg/BUILD\""),
          String.replace(diff, "-1,2", "-1,3"),
          String.replace(diff, "+1,2", "+2,2"),
          String.replace(diff, "-b\n", "-wrong\n"),
          diff <> "\\ No newline at end of file\n",
          "Binary files differ\n",
          diff <> <<0>>,
          <<255>>,
          String.duplicate("x", 1_048_577)
        ] do
      assert {:error, :controller_generation_diff_rejected} =
               TicketCiGenerationDiff.plan("gazelle", malformed, "/fixture/source", ["pkg/BUILD"], %{"pkg/BUILD" => before})
    end

    assert {:error, :controller_generation_diff_rejected} =
             TicketCiGenerationDiff.plan("gofmt", diff, "/fixture/source", ["pkg/BUILD"], %{"pkg/BUILD" => before})
  end

  test "single-line ranges and exact insertions or deletions preserve hunk coordinates" do
    for {before, range, body, after_text} <- [
          {"a\n", "-1 +1", "-a\n+b\n", "b\n"},
          {"", "-0,0 +1", "+a\n", "a\n"},
          {"a\n", "-1 +0,0", "-a\n", ""}
        ] do
      diff = "--- pkg/BUILD\n+++ pkg/BUILD\n@@ #{range} @@\n#{body}"
      assert {:ok, [%{after: ^after_text}]} = TicketCiGenerationDiff.plan("gazelle", diff, "/fixture/source", ["pkg/BUILD"], %{"pkg/BUILD" => before})
    end
  end

  test "a small byte frame with excessive tiny hunks is rejected before applying proposals" do
    before = Enum.map_join(1..129, &"old#{&1}\n")
    hunks = Enum.map_join(1..129, &"@@ -#{&1} +#{&1} @@\n-old#{&1}\n+new#{&1}\n")
    diff = "--- pkg/BUILD\n+++ pkg/BUILD\n" <> hunks
    assert byte_size(diff) < 16_384
    assert {:error, :controller_generation_diff_rejected} = TicketCiGenerationDiff.plan("gazelle", diff, "/fixture/source", ["pkg/BUILD"], %{"pkg/BUILD" => before})
  end

  test "gofmt stdin labels map only the header to the one controller-bound input" do
    before = "package p\nvar x=1\n"
    raw = "diff <standard input>.orig <standard input>\n--- <standard input>.orig\n+++ <standard input>\n@@ -1,2 +1,2 @@\n package p\n-var x=1\n+var x = 1\n"
    assert {:ok, [%{path: "pkg/p.go", before: ^before, after: "package p\nvar x = 1\n"}]} = TicketCiGenerationDiff.plan_stdin(raw, "/fixture/source", "pkg/p.go", before)
    assert {:error, :controller_generation_diff_rejected} = TicketCiGenerationDiff.plan_stdin(String.replace(raw, "<standard input>", "foreign.go"), "/fixture/source", "pkg/p.go", before)
    assert {:error, :controller_generation_diff_rejected} = TicketCiGenerationDiff.plan_stdin(raw, "/fixture/source", "../p.go", before)
  end
end
