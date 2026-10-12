(** Append-only log of normalized {!Event.t}s, framed like {!Frame_log}.

    One file per instrument, stream and UTC day of [recv_ts]:
    [<dir>/<venue>/<symbol>/norm/<stream>/<YYYY-MM-DD>.bin].

    Each new file starts with a {!Framed.File_header} carrying {!digest}. Readers accept
    any digest in {!compatible_digests} and raise, listing them, on a file whose header
    names another, rather than decoding garbage; files from before headers existed have
    none and are read unchecked.

    {2 Changing the event type}

    Follow the Stable discipline: [Event.Stable.V1] may only change in ways that keep old
    bytes decoding the same (appending a variant constructor at the end, here and in any
    nested stable type). Then:

    + Add the new [bin_shape] digest at the head of {!compatible_digests}, with a comment
      naming the change; never remove or reorder an entry.
    + Check in a fixture written by the previous code (a scratch [git worktree] at the
      commit before the change, running [Event_log.Writer]) and a test that reads it.
    + A change that is not backwards compatible needs [Event.Stable.V2] and a new reader,
      not a list entry. *)

open! Core

(** Hex [bin_shape] digest of {!Event.Stable.V1.t}, written into new files. *)
val digest : string

(** Digests whose files today's reader decodes, newest first; the head is {!digest}.
    Append-only. *)
val compatible_digests : string list

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

(** Events of one file in file order, stopping at a damaged tail. Raises on a digest not
    in {!compatible_digests}. *)
val read_file : string -> Event.t Async.Pipe.Reader.t * Framed.Tail.t Async.Deferred.t

val load_file : string -> (Event.t list * Framed.Tail.t) Async.Deferred.t

(** Events of several files merged by [recv_ts] (ties in file order). *)
val read_merged : string list -> Event.t Async.Pipe.Reader.t
