(*_ Fixtures shared by the tests. *)

open! Core
open Market_data

val btc : Instrument.t

(** [ts ms] is the Unix epoch plus [ms] milliseconds after 2026-01-01 00:00 UTC. *)
val ts : int -> Time_ns.t

val trade
  :  ?side:Side.t
  -> ?id:string
  -> ms:int
  -> price:string
  -> size:string
  -> unit
  -> Trade.t

(** Prints the bin_io round trip and size of [v]. *)
val bin_round_trip
  :  (module Binable.S with type t = 'a)
  -> equal:('a -> 'a -> bool)
  -> 'a
  -> unit
