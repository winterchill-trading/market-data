(** DuckDB views over the Parquet tables of every instrument under a root directory, and a
    runner for the [duckdb] CLI.

    {v
    CREATE VIEW trades AS SELECT * FROM read_parquet(
      '<dir>/*/*/parquet/trades/*.parquet', hive_partitioning=false);
    v} *)

open! Core
open! Async

(** [<dir>/*/*/parquet/<kind>/*.parquet] *)
val glob : dir:string -> Parquet_kind.t -> string

(** One [CREATE VIEW] statement, named after the kind. *)
val create_view : dir:string -> Parquet_kind.t -> string

(** [create_view] of each kind, one per line. [kinds] defaults to all of them. *)
val sql : ?kinds:Parquet_kind.t list -> dir:string -> unit -> string

(** Kinds with at least one [.parquet] file under [dir]. DuckDB refuses to create a view
    over a glob that matches nothing. *)
val existing_kinds : dir:string -> Parquet_kind.t list Deferred.t

module Format : sig
  (** DuckDB CLI output modes. *)
  type t =
    | Box
    | Csv
    | Json
    | Markdown
  [@@deriving sexp, compare, equal, enumerate]

  (** ["box"], ["csv"], ["json"], ["markdown"] *)
  val to_string : t -> string
end

(** Runs [sql] with [duckdb] (default ["duckdb"], looked up on [PATH]) on an in-memory
    database after creating the views of {!existing_kinds}. Returns standard output, or an
    error with standard error when DuckDB fails. [format] defaults to [Box]. *)
val query
  :  ?duckdb:string
  -> ?format:Format.t
  -> dir:string
  -> string
  -> string Or_error.t Deferred.t
