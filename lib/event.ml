open! Core

module Stable = struct
  module V1 = struct
    type t =
      | Trade of Trade.Stable.V1.t
      | Bbo of Bbo.Stable.V1.t
      | L2 of L2_update.Stable.V1.t
      | Funding of Funding.Stable.V1.t
    [@@deriving bin_io, sexp, compare, equal]
  end
end

include Stable.V1

let instrument = function
  | Trade x -> x.instrument
  | Bbo x -> x.instrument
  | L2 x -> x.instrument
  | Funding x -> x.instrument
;;

let exch_ts = function
  | Trade x -> x.exch_ts
  | Bbo x -> x.exch_ts
  | L2 x -> x.exch_ts
  | Funding x -> x.exch_ts
;;

let recv_ts = function
  | Trade x -> x.recv_ts
  | Bbo x -> x.recv_ts
  | L2 x -> x.recv_ts
  | Funding x -> x.recv_ts
;;

let stream : t -> Stream.t = function
  | Trade _ -> Trades
  | Bbo _ -> Bbo
  | L2 _ -> L2
  | Funding _ -> Funding
;;

let compare_by_recv_ts a b = Time_ns.compare (recv_ts a) (recv_ts b)
