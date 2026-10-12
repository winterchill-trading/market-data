(** The point-in-time universe of a UTC day: one row per instrument that has at least one
    [norm/] event log file that day, with its {!Instrument_info} facts as they are when
    the table is written. Day close writes it to

    {v
    <dir>/instruments/<YYYY-MM-DD>.parquet
    v}

    so a backtest can ask which instruments existed on a past day, and with which tick,
    lot and size unit, instead of reading today's catalogue. [instruments] is not a venue
    name, so {!Store.instruments} skips the directory. *)

open! Core
module Md_stream = Stream
open! Async

module Row : sig
  type t =
    { date : Date.t
    ; instrument : Instrument.t
    ; streams : Md_stream.t list
    (** streams with an event log that day, in stream order *)
    ; info : Instrument_info.t option (** [None] when the catalogue does not list it *)
    }
  [@@deriving sexp_of, compare, equal]
end

(** Columns: [date] (["YYYY-MM-DD"]), [venue], [symbol], [streams] (comma separated, e.g.
    ["trades,bbo,l2"]), [in_catalogue] (bool), then from the catalogue, empty, zero or NaN
    when [in_catalogue] is false: [kind] (["spot"], ["perp"], ["future"], ["option"]),
    [base], [quote], [size_unit] (["base"], ["quote"], ["contracts"]),
    [units_per_contract] (double, NaN for quote-sized), [units_per_price] (double),
    [funding_interval_s] (int64, 0 when the instrument does not fund), [tick] and [lot]
    ([DECIMAL(18, 8)]). *)
val schema : Row.t Parquet.Schema.t

(** [<dir>/instruments] *)
val table_dir : dir:string -> string

(** [<dir>/instruments/<YYYY-MM-DD>.parquet] *)
val path : dir:string -> Date.t -> string

(** [<dir>/instruments/*.parquet] *)
val glob : dir:string -> string

(** The rows of [date]: instruments under [dir] with a [norm/] file that day, sorted.
    [catalogue] defaults to {!Instrument_info.catalogue}. *)
val rows
  :  ?catalogue:Instrument_info.t list
  -> dir:string
  -> Date.t
  -> Row.t list Deferred.t

(** Writes {!rows} to {!path} (atomically, through {!Parquet_file}) and returns the row
    count. A day with no event logs writes no file and returns 0. *)
val write
  :  ?compression:[ `None | `Zstd ]
  -> ?catalogue:Instrument_info.t list
  -> dir:string
  -> Date.t
  -> int Deferred.t
