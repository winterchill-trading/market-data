(** On-disk layout of recorded market data under a root directory:

    {v
    <root>/<venue>/<symbol>/raw/<stream>/<YYYY-MM-DD>.binlog   Frame_log
    <root>/<venue>/<symbol>/norm/<stream>/<YYYY-MM-DD>.bin     Event_log
    v}

    Days are UTC dates of the local receive time. *)

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

val instrument_dir : t -> Instrument.t -> string
val stream_dir : t -> Layer.t -> Instrument.t -> Stream.t -> string
val path : t -> Layer.t -> Instrument.t -> Stream.t -> Date.t -> string

(** Days with a file for this stream, ascending. Empty if the directory is missing; files
    whose names are not dates are ignored. *)
val days : t -> Layer.t -> Instrument.t -> Stream.t -> Date.t list Async.Deferred.t

(** Instruments with a directory under the root, sorted. Unknown venue directories are
    ignored. *)
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
