(** A normalized market data event. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      | Trade of Trade.Stable.V1.t
      | Bbo of Bbo.Stable.V1.t
      | L2 of L2_update.Stable.V1.t
      | Funding of Funding.Stable.V1.t
    [@@deriving bin_io, sexp, compare, equal, quickcheck]
  end
end

type t = Stable.V1.t =
  | Trade of Trade.t
  | Bbo of Bbo.t
  | L2 of L2_update.t
  | Funding of Funding.t
[@@deriving bin_io, sexp, compare, equal]

val instrument : t -> Instrument.t
val exch_ts : t -> Time_ns.t
val recv_ts : t -> Time_ns.t

(** The stream the event belongs to ([Trades], [Bbo], [L2] or [Funding]). *)
val stream : t -> Stream.t

(** Orders by [recv_ts] only. *)
val compare_by_recv_ts : t -> t -> int
