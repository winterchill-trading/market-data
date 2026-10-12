open! Core

module Stable = struct
  module V1 = struct
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

let of_stable : Stable.V1.t -> t = function
  | Trade x -> Trade x
  | Bbo x -> Bbo x
  | L2 x -> L2 x
  | Funding x -> Funding x
  | Funding_v2 x -> Funding (Funding.of_v2 x)
;;

let to_stable : t -> Stable.V1.t = function
  | Trade x -> Trade x
  | Bbo x -> Bbo x
  | L2 x -> L2 x
  | Funding x ->
    (match Funding.exch_ts_opt x with
     | Some _ -> Funding x
     | None -> Funding_v2 (Funding.to_v2 x))
;;

(* Written by hand rather than through [to_stable] so that writing a trade, BBO or L2
   event allocates nothing. The tags are those [Stable.V1] derives: one byte each, in
   constructor order. *)
module Bin = struct
  let tag_trade = 0
  let tag_bbo = 1
  let tag_l2 = 2
  let tag_funding = 3
  let tag_funding_v2 = 4

  let bin_size_t = function
    | Trade x -> 1 + Trade.Stable.V1.bin_size_t x
    | Bbo x -> 1 + Bbo.Stable.V1.bin_size_t x
    | L2 x -> 1 + L2_update.Stable.V1.bin_size_t x
    | Funding x ->
      (match Funding.exch_ts_opt x with
       | Some _ -> 1 + Funding.Stable.V1.bin_size_t x
       | None -> 1 + Funding.Stable.V2.bin_size_t (Funding.to_v2 x))
  ;;

  let bin_write_t buf ~pos t =
    let tag pos n = Bin_prot.Write.bin_write_int_8bit buf ~pos n in
    match t with
    | Trade x -> Trade.Stable.V1.bin_write_t buf ~pos:(tag pos tag_trade) x
    | Bbo x -> Bbo.Stable.V1.bin_write_t buf ~pos:(tag pos tag_bbo) x
    | L2 x -> L2_update.Stable.V1.bin_write_t buf ~pos:(tag pos tag_l2) x
    | Funding x ->
      (match Funding.exch_ts_opt x with
       | Some _ -> Funding.Stable.V1.bin_write_t buf ~pos:(tag pos tag_funding) x
       | None ->
         Funding.Stable.V2.bin_write_t buf ~pos:(tag pos tag_funding_v2) (Funding.to_v2 x))
  ;;

  let bin_read_t buf ~pos_ref = of_stable (Stable.V1.bin_read_t buf ~pos_ref)
  let __bin_read_t__ buf ~pos_ref n = of_stable (Stable.V1.__bin_read_t__ buf ~pos_ref n)
  let bin_shape_t = Stable.V1.bin_shape_t

  let bin_writer_t : t Bin_prot.Type_class.writer =
    { size = bin_size_t; write = bin_write_t }
  ;;

  let bin_reader_t : t Bin_prot.Type_class.reader =
    { read = bin_read_t; vtag_read = __bin_read_t__ }
  ;;

  let bin_t : t Bin_prot.Type_class.t =
    { shape = bin_shape_t; writer = bin_writer_t; reader = bin_reader_t }
  ;;
end

include Bin

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
