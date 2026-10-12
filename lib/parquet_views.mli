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

(** Views and tables derived from the tables in [kinds]:
    - [trades_with_bbo] (needs trades and bbo): each trade with the bbo prevailing at its
      [recv_ts] (DuckDB [ASOF LEFT JOIN] on venue and symbol), columns [bbo_recv_ts],
      [bid_price], [bid_size], [ask_price], [ask_size] after the trade's own;
    - [lag]: per table, venue and symbol, [n], [p50_ms] and [p99_ms] of
      [recv_ts - exch_ts];
    - [units_per_contract] (always): {!Contract_units.create_table_sql} with [units_csv];
    - [token_bbo] (needs bbo): bbo of the instruments in [units_per_contract] in token
      terms: [token], [bid], [ask], [mid] per token, [bid_qty], [ask_qty] in tokens. *)
val derived_sql : ?units_csv:string -> Parquet_kind.t list -> string

(** [<dir>/units_per_contract.csv] if it exists. *)
val units_csv : dir:string -> string option Deferred.t

(** Kinds with at least one [.parquet] file under [dir]. DuckDB refuses to create a view
    over a glob that matches nothing. *)
val existing_kinds : dir:string -> Parquet_kind.t list Deferred.t

(** [CREATE VIEW instruments] over {!Instruments_table.glob}. *)
val instruments_view : dir:string -> string

(** {!instruments_view} when [<dir>/instruments] holds a [.parquet] file. *)
val existing_instruments_view : dir:string -> string option Deferred.t

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
    database after creating the views of {!existing_kinds}, {!existing_instruments_view}
    and their {!derived_sql}. Returns standard output, or an error with standard error
    when DuckDB fails. [format] defaults to [Box]. *)
val query
  :  ?duckdb:string
  -> ?format:Format.t
  -> dir:string
  -> string
  -> string Or_error.t Deferred.t
