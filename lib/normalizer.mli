(** What a venue feed library provides so that {!Rebuild_norm} can turn its raw frames
    back into events. Market-data has no venue code; each feed repository satisfies {!S}
    with a thin adapter over its own normalizer, e.g.

    {[
      module Okx_normalizer : Market_data.Normalizer.S = struct
        type t = Okx_feed.Normalizer.t

        let venue = Market_data.Venue.Okx
        let create () = Okx_feed.Normalizer.create ()

        let frame t ~recv_ts payload =
          Or_error.map (Okx_feed.Normalizer.frame t ~recv_ts payload) ~f:(fun o ->
            o.events)
        ;;

        let disconnect t = Okx_feed.Normalizer.reset t
      end
    ]} *)

open! Core

module type S = sig
  (** Per-connection state: book sequences, partial funding records. *)
  type t

  val venue : Venue.t

  (** A fresh state; one is created per raw [(stream, symbol)] series. *)
  val create : unit -> t

  (** The events of one raw frame, in order. [Error] for frames that do not parse;
      subscription acks and heartbeats give [Ok []]. *)
  val frame : t -> recv_ts:Time_ns.t -> string -> Event.t list Or_error.t

  (** The recorder saw the connection drop; the next frames start a new one. *)
  val disconnect : t -> unit
end

type t = (module S)

val venue : t -> Venue.t
