(** Converts a closed day of {!Event_log} files into Parquet: the batch path that rebuilds
    [parquet/] from [norm/], with the same layout as {!Parquet_sink}.

    For each instrument, [norm/trades], [norm/bbo], [norm/l2] and [norm/funding] of the
    day become the tables of the same name, and the trades also become [candles] (default
    interval one minute). A table is skipped when its [<date>.parquet] exists and is newer
    than the source file, so re-running is cheap; when it is rewritten, numbered parts
    [<date>.<n>.parquet] left by a restarted sink are removed, since the rebuilt file
    covers the whole day. *)

open! Core
open! Async

module Outcome : sig
  type t =
    | Written of
        { rows : int
        ; tail : Framed.Tail.t (** how the source file ended *)
        }
    | Up_to_date
    | No_source
  [@@deriving sexp_of, compare, equal]
end

module Result : sig
  type t =
    { instrument : Instrument.t
    ; kind : Parquet_kind.t
    ; path : string
    ; outcome : Outcome.t
    }
  [@@deriving sexp_of]
end

(** [instruments] defaults to every instrument under [dir]. [force] rewrites tables that
    are up to date. [row_group_rows] defaults to 1_048_576, [candle_interval] to one
    minute. *)
val run
  :  ?compression:[ `None | `Zstd ]
  -> ?row_group_rows:int
  -> ?candle_interval:Time_ns.Span.t
  -> ?force:bool
  -> ?instruments:Instrument.t list
  -> dir:string
  -> Date.t
  -> Result.t list Deferred.t
