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

(** A feed that also reports breaks ({!Gap.t}): disconnects and resyncs. A separate
    signature so feeds that do not report gaps keep satisfying {!S}. *)
module With_gaps : sig
  module type S = sig
    include S

    (** Written without pushback, so leaving it unread never stalls the feed. Closes with
        the feed. *)
    val gaps : Gap.t Pipe.Reader.t
  end

  type feed := t
  type t = (module S)

  val to_feed : t -> feed

  (** A feed that never reports a gap; [gaps] closes once every other pipe has closed or
      [close] is called. *)
  val of_feed : feed -> t
end
