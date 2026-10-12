open! Core
open! Async

module type S = sig
  val trades : Trade.t Pipe.Reader.t
  val bbo : Bbo.t Pipe.Reader.t
  val l2 : L2_update.t Pipe.Reader.t
  val funding : Funding.t Pipe.Reader.t
  val close : unit -> unit Deferred.t
end

type t = (module S)
