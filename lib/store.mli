(** On-disk layout of recorded market data under a root directory:

    {v
    <root>/<venue>/<symbol>/raw/<stream>/<YYYY-MM-DD>.binlog   Frame_log
    <root>/<venue>/<symbol>/norm/<stream>/<YYYY-MM-DD>.bin     Event_log
    v}

    Days are UTC dates of the local receive time. A [/] in a symbol (Kraken spot,
    [BTC/USD]) becomes [_] in its directory name ({!symbol_dir_name}); every other symbol
    is used as is. *)

open! Core

module Layer : sig
  type t =
    | Raw (** venue messages as received *)
    | Norm (** normalized events *)
  [@@deriving sexp, compare, equal, enumerate]

  (** ["raw"] or ["norm"] *)
  val to_string : t -> string

  (** [".binlog"] or [".bin"] *)
  val extension : t -> string
end

type t [@@deriving sexp_of]

val create : string -> t
val root : t -> string

(** UTC date of a timestamp: the day whose file holds it. *)
val date_of_time : Time_ns.t -> Date.t

(** The directory name of a symbol: [/] replaced by [_], e.g. [BTC/USD] to [BTC_USD]. *)
val symbol_dir_name : string -> string

(** Inverse of {!symbol_dir_name} where it is unambiguous: on Kraken, a name with [_] that
    is not a futures symbol ([PF_], [PI_], [FI_], [FF_]) is a spot pair, [BTC_USD] to
    [BTC/USD]. Other names are returned unchanged. *)
val symbol_of_dir_name : Venue.t -> string -> string

(** [<root>/<venue>/<symbol_dir_name symbol>] *)
val instrument_dir : t -> Instrument.t -> string

val stream_dir : t -> Layer.t -> Instrument.t -> Stream.t -> string
val path : t -> Layer.t -> Instrument.t -> Stream.t -> Date.t -> string

(** Days with a file for this stream, ascending. Empty if the directory is missing; files
    whose names are not dates are ignored. *)
val days : t -> Layer.t -> Instrument.t -> Stream.t -> Date.t list Async.Deferred.t

(** Instruments with a directory under the root, sorted, symbols mapped back with
    {!symbol_of_dir_name}. Unknown venue directories are ignored. *)
val instruments : t -> Instrument.t list Async.Deferred.t

(** Existing files of the given streams for days in [[from, to_]], sorted by day then
    stream order. *)
val files
  :  t
  -> Layer.t
  -> Instrument.t
  -> Stream.t list
  -> from:Date.t
  -> to_:Date.t
  -> string list Async.Deferred.t
