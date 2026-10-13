defmodule Barkpark.SchemaDiffTest do
  @moduledoc "task-097a1b8ed6d27a8b, criterion 1, on pg_dump-shaped text."
  use ExUnit.Case, async: true

  alias Barkpark.SchemaDiff

  @dump """
  --
  -- PostgreSQL database dump
  --

  \\restrict abc123

  SET statement_timeout = 0;
  SELECT pg_catalog.set_config('search_path', '', false);

  CREATE EXTENSION IF NOT EXISTS citext WITH SCHEMA public;

  CREATE FUNCTION public.f_immutable() RETURNS trigger
      LANGUAGE plpgsql
      AS $$
  BEGIN
    RAISE EXCEPTION 'immutable';
    RETURN NULL;
  END;
  $$;

  CREATE TABLE public.things (
      id bigint NOT NULL,
      name text
  );

  COMMENT ON TABLE public.oban_jobs IS '14';

  CREATE SEQUENCE public.things_id_seq
      START WITH 1
      INCREMENT BY 1;

  ALTER SEQUENCE public.things_id_seq OWNED BY public.things.id;

  ALTER TABLE ONLY public.things ALTER COLUMN id SET DEFAULT nextval('public.things_id_seq'::regclass);

  ALTER TABLE ONLY public.things
      ADD CONSTRAINT things_pkey PRIMARY KEY (id);

  CREATE UNIQUE INDEX things_name_index ON public.things USING btree (name);

  CREATE CONSTRAINT TRIGGER things_check AFTER INSERT ON public.things DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION public.f_immutable();

  \\unrestrict abc123
  """

  test "keys each statement by the object it creates" do
    keys = @dump |> SchemaDiff.objects() |> Map.keys() |> Enum.sort()

    assert keys == [
             {"comment", "TABLE oban_jobs"},
             {"constraint", "things.things_pkey"},
             {"default", "things.id"},
             {"extension", "citext"},
             {"function", "f_immutable()"},
             {"index", "things_name_index"},
             {"sequence", "things_id_seq"},
             {"sequence owner", "things_id_seq"},
             {"table", "things"},
             {"trigger", "things.things_check"}
           ]
  end

  test "a function body's own semicolons stay in its statement" do
    body = Map.fetch!(SchemaDiff.objects(@dump), {"function", "f_immutable()"})
    assert body =~ "RAISE EXCEPTION 'immutable'; RETURN NULL; END; $$;"
  end

  test "two identical dumps differ in nothing, whatever their restrict keys and spacing" do
    other = @dump |> String.replace("abc123", "zzz999") |> String.replace("    ", "  ")
    assert SchemaDiff.diff(@dump, other) == []
  end

  test "a planted difference names its object" do
    planted =
      String.replace(@dump, "    name text\n", "    name text,\n    extra integer\n")
      |> String.replace("CREATE UNIQUE INDEX things_name_index", "CREATE INDEX things_name_index")
      |> String.replace("COMMENT ON TABLE public.oban_jobs IS '14';", "")

    lines = planted |> then(&SchemaDiff.diff(@dump, &1)) |> Enum.map(&SchemaDiff.format/1)

    assert "differs:   table things\n    B: extra integer" in lines
    assert Enum.any?(lines, &String.starts_with?(&1, "differs:   index things_name_index"))
    assert "only in A: comment TABLE oban_jobs" in lines
    assert length(lines) == 3
  end

  test "an unkeyed statement is keyed by its text, so a change shows as removed and added" do
    a = "CREATE AGGREGATE public.agg(int) (SFUNC = int4pl, STYPE = int);\n"
    b = "CREATE AGGREGATE public.agg(int) (SFUNC = int4mul, STYPE = int);\n"

    assert [{:only_in_a, {"statement", _}}, {:only_in_b, {"statement", _}}] =
             SchemaDiff.diff(a, b) |> Enum.sort()
  end
end
