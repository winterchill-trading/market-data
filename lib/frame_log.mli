(** Raw, append-only log of venue messages exactly as received.

    One file per instrument, stream and UTC day:
    [<dir>/<venue>/<symbol>/raw/<stream>/<YYYY-MM-DD>.binlog]. Each file is a sequence of
    {!Framed} frames holding a {!Record.t}. Nothing is parsed on the write path; the
    normalizers read these files later. *)

open! Core

module Record : sig
  module Stable : sig
    module V1 : sig
      type t =
        { recv_ts : Time_ns.Stable.V1.t
        ; stream_id : int
        (** identifies the connection or subscription the payload arrived on *)
        ; payload : string (** the message bytes, unparsed *)
        }
      [@@deriving bin_io, sexp, compare, equal, fields]
    end
  end

  type t = Stable.V1.t =
    { recv_ts : Time_ns.t
    ; stream_id : int
    ; payload : string
    }
  [@@deriving bin_io, sexp, compare, equal, fields]
end

(** [<dir>/<venue>/<symbol>/raw/<stream>/<YYYY-MM-DD>.binlog] *)
val path : dir:string -> Instrument.t -> Stream.t -> Date.t -> string

module Writer : sig
  type t

  (** See {!Framed.Writer} for the flush policy. *)
  val create
    :  ?flush_interval:Time_ns.Span.t
    -> ?flush_bytes:int
    -> dir:string
    -> Instrument.t
    -> Stream.t
    -> t

  (** Appends to the file of the record's [recv_ts] day. *)
  val append : t -> Record.t -> unit

  val write : t -> recv_ts:Time_ns.t -> stream_id:int -> string -> unit
  val flush : t -> unit Async.Deferred.t
  val close : t -> unit Async.Deferred.t

  (** Files opened so far, in order. *)
  val files : t -> string list
end

(** Records of one file in file order, stopping at a damaged tail. *)
val read_file : string -> Record.t Async.Pipe.Reader.t * Framed.Tail.t Async.Deferred.t

val load_file : string -> (Record.t list * Framed.Tail.t) Async.Deferred.t

(** Records of several files merged by [recv_ts] (ties in file order). Each file is
    assumed sorted by [recv_ts], which holds for files written by one {!Writer}. Damaged
    tails are skipped. *)
val read_merged : string list -> Record.t Async.Pipe.Reader.t
