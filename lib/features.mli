(** Builds the feature tables of a day ({!Feature_schemas}) from the normalized trades in
    [norm/]: information-driven bars ({!Bars}) of every requested kind in one table, and
    VPIN toxicity buckets ({!Toxicity}) in another. Like [day-close], a rebuild writes
    [<path>.tmp] and renames it, replacing the previous file. *)

open! Core
open! Async

(** The toxicity bucket size. *)
module Bucket : sig
  type t =
    | Fixed of Size.t
    | Per_day of int
    (** the day's traded volume of the instrument divided by this many buckets (rounded
        down to 10^-8, at least one unit); reads the trades twice *)
  [@@deriving sexp, compare, equal]
end

module Toxicity_spec : sig
  type t =
    { bucket : Bucket.t
    ; window : int
    ; zscore_window : int
    ; classification : Toxicity.Classification.t
    }
  [@@deriving sexp, compare, equal]

  (** 50 buckets a day, window 50, z-score over 250 buckets, [Aggressor]. *)
  val default : t
end

module Result : sig
  type t =
    { instrument : Instrument.t
    ; trades : int
    ; bars : (string * int) option (** path and rows, when bars were requested *)
    ; toxicity : (string * int * Size.t) option (** path, rows and bucket volume *)
    }
  [@@deriving sexp_of]
end

(** [<dir>/<venue>/<symbol>/parquet/bars/<date>.parquet] *)
val bars_path : dir:string -> Instrument.t -> Date.t -> string

(** [<dir>/<venue>/<symbol>/parquet/toxicity/<date>.parquet] *)
val toxicity_path : dir:string -> Instrument.t -> Date.t -> string

(** For each instrument (default every one under [dir]) with a trades event log on [date]:
    one bars file holding the bars of every spec in [bars] (none written when [bars] is
    empty), including each spec's partial last bar with [complete = false], and one
    toxicity file when [toxicity] is given. Instruments without trades that day are left
    out of the result. *)
val run
  :  ?instruments:Instrument.t list
  -> ?toxicity:Toxicity_spec.t
  -> dir:string
  -> bars:Bars.Spec.t list
  -> Date.t
  -> Result.t list Deferred.t

(** The [features] subcommand. *)
val command : Command.t
