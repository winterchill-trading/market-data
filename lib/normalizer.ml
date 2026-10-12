open! Core

module type S = sig
  type t

  val venue : Venue.t
  val create : unit -> t
  val frame : t -> recv_ts:Time_ns.t -> string -> Event.t list Or_error.t
  val disconnect : t -> unit
end

type t = (module S)

let venue (module N : S) = N.venue
