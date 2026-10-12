(** A break in a feed: data between the previous event and the next one may be missing, so
    books and other derived state must be rebuilt from the next snapshot. *)

open! Core
module Md_stream := Stream

module Reason : sig
  type t =
    | Disconnect (** the connection dropped (an empty raw line when recorded) *)
    | Resync (** the feed detected a sequence break and resubscribed *)
    | Damaged_log (** an event log ends in a truncated or corrupt frame *)
  [@@deriving sexp, compare, equal]
end

type t =
  { recv_ts : Time_ns.t (** when the break was noticed *)
  ; venue : Venue.t
  ; instrument : Instrument.t option (** [None]: every instrument of the connection *)
  ; stream : Md_stream.t option (** [None]: every stream *)
  ; reason : Reason.t
  }
[@@deriving sexp_of, compare, equal]
