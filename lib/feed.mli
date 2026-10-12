(** A source of normalized market data: live venue connections or a replay of recorded
    events. *)

open! Core
open! Async

module type S = sig
  val trades : Trade.t Pipe.Reader.t
  val bbo : Bbo.t Pipe.Reader.t
  val l2 : L2_update.t Pipe.Reader.t
  val funding : Funding.t Pipe.Reader.t

  (** Stops the feed and closes all its pipes. *)
  val close : unit -> unit Deferred.t
end

type t = (module S)
