(** Data-quality assertions over the Parquet tables, run with DuckDB.

    Checks, each counted per table that has files:
    - [recv_ts_gap] (trades, bbo, l2): consecutive [recv_ts] of one instrument further
      apart than [max_gap];
    - [non_positive_size]: trades with [size <= 0], bbo with a side size [<= 0], l2 levels
      with a negative size or a zero size in a snapshot (zero removes a level only in a
      delta);
    - [crossed_bbo]: bbo with [bid_price > ask_price].

    The gaps are also a view, [gaps], with one row per gap:
    [table_name, venue, symbol, from_ts, to_ts, gap_ms]. *)

open! Core
open! Async

module Check : sig
  type t =
    { name : string
    ; table : Parquet_kind.t
    ; violations : int
    }
  [@@deriving sexp_of, compare, equal]
end

(** [CREATE VIEW gaps AS ...] over the gap-checked tables among [kinds]. *)
val gaps_view : max_gap:Time_ns.Span.t -> Parquet_kind.t list -> string

(** One row per check: [check_name, table_name, violations]. *)
val summary_sql : Parquet_kind.t list -> string

module Report : sig
  type t =
    { checks : Check.t list
    ; gaps : string (** the largest gaps, as CSV with a header *)
    }

  val failed : t -> Check.t list
end

(** [max_gap] defaults to one minute, [show_gaps] (rows of {!Report.gaps}) to 20. *)
val run
  :  ?duckdb:string
  -> ?max_gap:Time_ns.Span.t
  -> ?show_gaps:int
  -> dir:string
  -> unit
  -> Report.t Or_error.t Deferred.t
