open! Core

(* [Time_ns.Stable.Span.V2] has no quickcheck functions; borrow the unstable ones. *)
module Span_v2 = struct
  include Time_ns.Stable.Span.V2

  let quickcheck_generator = Time_ns.Span.quickcheck_generator
  let quickcheck_observer = Time_ns.Span.quickcheck_observer
  let quickcheck_shrinker = Time_ns.Span.quickcheck_shrinker
end

module Stable = struct
  module V1 = struct
    type t =
      { instrument : Instrument.Stable.V1.t
      ; interval : Span_v2.t
      ; open_time : Time_ns.Stable.V1.t
      ; open_ : Price.Stable.V1.t
      ; high : Price.Stable.V1.t
      ; low : Price.Stable.V1.t
      ; close : Price.Stable.V1.t
      ; volume : Size.Stable.V1.t
      ; trade_count : int
      }
    [@@deriving bin_io, sexp, compare, equal, quickcheck, fields]
  end
end

include Stable.V1

let close_time t = Time_ns.add t.open_time t.interval
