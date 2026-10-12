(** Tables written as Parquet, one directory each next to [raw/] and [norm/]:

    {v
    <root>/<venue>/<symbol>/parquet/<kind>/<YYYY-MM-DD>.parquet
    v} *)

open! Core

type t =
  | Trades
  | Bbo
  | L2
  | Funding
  | Candles
[@@deriving sexp, compare, equal, hash, enumerate]

(** Directory and DuckDB view name: ["trades"], ["bbo"], ["l2"], ["funding"], ["candles"]. *)
val to_string : t -> string

(** Inverse of {!to_string}; case-insensitive. Raises on unknown names. *)
val of_string : string -> t

(** The parquet table of a normalized stream; [None] for [Private]. *)
val of_stream : Stream.t -> t option

(** [<dir>/<venue>/<symbol>/parquet/<kind>] *)
val kind_dir : dir:string -> Instrument.t -> t -> string

(** [<dir>/<venue>/<symbol>/parquet/<kind>/<YYYY-MM-DD>.parquet] *)
val path : dir:string -> Instrument.t -> t -> Date.t -> string
