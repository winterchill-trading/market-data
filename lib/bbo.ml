open! Core

module Stable = struct
  module V1 = struct
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t
      ; recv_ts : Time_ns.Stable.V1.t
      ; bid_price : Price.Stable.V1.t
      ; bid_size : Size.Stable.V1.t
      ; ask_price : Price.Stable.V1.t
      ; ask_size : Size.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal, quickcheck, fields]
  end
end

include Stable.V1

let mid t = Price.div_int Price.(t.bid_price + t.ask_price) 2
let spread t = Price.(t.ask_price - t.bid_price)
