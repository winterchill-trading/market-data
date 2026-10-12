(** Append-only log of normalized {!Event.t}s, framed like {!Frame_log}.

    One file per instrument, stream and UTC day of [recv_ts]:
    [<dir>/<venue>/<symbol>/norm/<stream>/<YYYY-MM-DD>.bin].

    Each new file starts with a {!Framed.File_header} carrying {!digest}. Readers raise on
    a file whose header names another digest, rather than decoding garbage; files from
    before headers existed have none and are read unchecked. *)

open! Core

(** Hex [bin_shape] digest of {!Event.Stable.V1.t}. *)
val digest : string

(** [<dir>/<venue>/<symbol>/norm/<stream>/<YYYY-MM-DD>.bin] *)
val path : dir:string -> Instrument.t -> Stream.t -> Date.t -> string

(** Routes each event to the file of its instrument, stream and day, opening files as
    needed. *)
module Writer : sig
  type t

  (** See {!Framed.Writer} for the flush policy, applied per file. *)
  val create
    :  ?flush_interval:Time_ns.Span.t
    -> ?flush_bytes:int
    -> dir:string
    -> unit
    -> t

  val append : t -> Event.t -> unit
  val flush : t -> unit Async.Deferred.t
  val close : t -> unit Async.Deferred.t

  (** Files opened so far, sorted. *)
  val files : t -> string list
end

(** Events of one file in file order, stopping at a damaged tail. Raises on a digest
    mismatch. *)
val read_file : string -> Event.t Async.Pipe.Reader.t * Framed.Tail.t Async.Deferred.t

val load_file : string -> (Event.t list * Framed.Tail.t) Async.Deferred.t

(** Events of several files merged by [recv_ts] (ties in file order). *)
val read_merged : string list -> Event.t Async.Pipe.Reader.t
