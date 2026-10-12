(** Converts a closed day of {!Event_log} files into Parquet: the batch path that rebuilds
    [parquet/] from [norm/], with the same layout as {!Parquet_sink}.

    For each instrument, [norm/trades], [norm/bbo], [norm/l2] and [norm/funding] of the
    day become the tables of the same name, and the trades also become [candles] (default
    interval one minute). Each written table gets a {!Manifest},
    [<kind dir>/_manifest/<date>.sexp], recording its inputs (size and mtime), output
    size, row count and {!Manifest.code_version}. A table is skipped when its
    [<date>.parquet] exists and its manifest matches the current inputs and code version,
    so re-running is cheap; a table without a manifest is rebuilt. When a table is
    rewritten, numbered parts [<date>.<n>.parquet] left by a restarted sink are removed,
    since the rebuilt file covers the whole day. *)

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

module Manifest : sig
  (** Changes when the conversion or the event type changes, forcing a rebuild. *)
  val code_version : string

  module Input : sig
    type t =
      { path : string (** relative to the root *)
      ; size : int
      ; mtime : float (** seconds since the epoch *)
      }
    [@@deriving sexp, compare, equal]
  end

  type t =
    { inputs : Input.t list
    ; output : string (** relative to the root *)
    ; output_bytes : int
    ; rows : int
    ; code_version : string
    }
  [@@deriving sexp, compare, equal]

  (** [<dir>/_manifest/<date>.sexp] for the table file [<dir>/<date>.parquet]. Dataset
      readers (pyarrow, Spark) skip directories starting with [_]. *)
  val path : string -> string

  (** The manifest of a table file, if present and readable. *)
  val load : string -> t option Deferred.t
end

(** What a table rebuild read and wrote. *)
module Stats : sig
  type t =
    { input_frames : int (** events read from the source file *)
    ; input_bytes : int
    ; replaced_parts : string list (** numbered sink parts removed, file names *)
    ; output_bytes : int
    ; elapsed : Time_ns.Span.t (** wall time of the rebuild *)
    }
  [@@deriving sexp_of]
end

module Result : sig
  type t =
    { instrument : Instrument.t
    ; kind : Parquet_kind.t
    ; path : string
    ; outcome : Outcome.t
    ; stats : Stats.t option (** present when the table was written *)
    }
  [@@deriving sexp_of]
end

(** [instruments] defaults to every instrument under [dir]. [force] rewrites tables that
    are up to date. [row_group_rows] defaults to 1_048_576, [candle_interval] to one
    minute. Up to [jobs] tables (default 1) are converted at once; Parquet encoding and
    writes run in [In_thread], so they overlap. Results are in instrument then table order
    whatever [jobs] is. *)
val run
  :  ?compression:[ `None | `Zstd ]
  -> ?row_group_rows:int
  -> ?candle_interval:Time_ns.Span.t
  -> ?force:bool
  -> ?jobs:int
  -> ?instruments:Instrument.t list
  -> dir:string
  -> Date.t
  -> Result.t list Deferred.t
