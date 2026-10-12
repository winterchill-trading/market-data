(** A normalized market data event. *)

open! Core

module Stable : sig
  (** The on-disk shape of {!Event_log} files. [Funding_v2] was appended after the other
      constructors, so files written before it decode unchanged
      ({!Event_log.compatible_digests}). *)
  module V1 : sig
    type t =
      | Trade of Trade.Stable.V1.t
      | Bbo of Bbo.Stable.V1.t
      | L2 of L2_update.Stable.V1.t
      | Funding of Funding.Stable.V1.t
      | Funding_v2 of Funding.Stable.V2.t
    [@@deriving bin_io, sexp, compare, equal, quickcheck]
  end
end

type t =
  | Trade of Trade.t
  | Bbo of Bbo.t
  | L2 of L2_update.t
  | Funding of Funding.t
[@@deriving sexp, compare, equal]

(** The binary shape is {!Stable.V1}: a funding event without an exchange timestamp
    ({!Funding.exch_ts_opt} is [None]) is written as [Funding_v2], every other event as
    the constructor of the same name, byte for byte. *)
include Binable.S with type t := t

(** [Funding_v2] becomes [Funding] through {!Funding.of_v2}. *)
val of_stable : Stable.V1.t -> t

(** The constructor the binary encoding writes. [of_stable (to_stable t) = t]. *)
val to_stable : t -> Stable.V1.t

val instrument : t -> Instrument.t
val exch_ts : t -> Time_ns.t
val recv_ts : t -> Time_ns.t

(** The stream the event belongs to ([Trades], [Bbo], [L2] or [Funding]). *)
val stream : t -> Stream.t

(** Orders by [recv_ts] only. *)
val compare_by_recv_ts : t -> t -> int
