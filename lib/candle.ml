open! Core

module Stable = struct
  module V1 = struct
    type t =
      { instrument : Instrument.Stable.V1.t
      ; interval : Time_ns.Stable.Span.V2.t
      ; open_time : Time_ns.Stable.V1.t
      ; open_ : Price.Stable.V1.t
      ; high : Price.Stable.V1.t
      ; low : Price.Stable.V1.t
      ; close : Price.Stable.V1.t
      ; volume : Size.Stable.V1.t
      ; trade_count : int
      }
    [@@deriving bin_io, sexp, compare, equal, fields]
  end
end

include Stable.V1

let close_time t = Time_ns.add t.open_time t.interval
