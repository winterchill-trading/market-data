open! Core

module Stable = struct
  module V1 = struct
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t
      ; recv_ts : Time_ns.Stable.V1.t
      ; price : Price.Stable.V1.t
      ; size : Size.Stable.V1.t
      ; side : Side.Stable.V1.t
      ; trade_id : string
      }
    [@@deriving bin_io, sexp, compare, equal, fields]
  end
end

include Stable.V1
