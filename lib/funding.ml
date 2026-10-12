open! Core

module Stable = struct
  module V1 = struct
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t
      ; recv_ts : Time_ns.Stable.V1.t
      ; rate : float
      ; next_funding_time : Time_ns.Stable.V1.t
      ; mark_price : Price.Stable.V1.t
      ; index_price : Price.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal, quickcheck, fields]
  end

  module V2 = struct
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t option
      ; recv_ts : Time_ns.Stable.V1.t
      ; rate : float
      ; next_funding_time : Time_ns.Stable.V1.t
      ; mark_price : Price.Stable.V1.t
      ; index_price : Price.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal, quickcheck]

    let of_v1
      ({ instrument; exch_ts; recv_ts; rate; next_funding_time; mark_price; index_price } :
        V1.t)
      =
      { instrument
      ; exch_ts = Some exch_ts
      ; recv_ts
      ; rate
      ; next_funding_time
      ; mark_price
      ; index_price
      }
    ;;

    let to_v1
      { instrument; exch_ts; recv_ts; rate; next_funding_time; mark_price; index_price }
      : V1.t
      =
      { instrument
      ; exch_ts = Option.value exch_ts ~default:recv_ts
      ; recv_ts
      ; rate
      ; next_funding_time
      ; mark_price
      ; index_price
      }
    ;;
  end
end

include Stable.V1

let exch_ts_opt t = if Time_ns.equal t.exch_ts t.recv_ts then None else Some t.exch_ts
let to_v2 t = { (Stable.V2.of_v1 t) with exch_ts = exch_ts_opt t }
let of_v2 = Stable.V2.to_v1
let eight_hours = Time_ns.Span.of_hr 8.

let normalized_8h ?funding_interval ?catalogue t =
  let interval =
    match funding_interval with
    | Some _ -> funding_interval
    | None ->
      Option.bind (Instrument_info.lookup ?catalogue t.instrument) ~f:(fun info ->
        info.funding_interval)
  in
  Option.bind interval ~f:(fun interval ->
    if Time_ns.Span.( <= ) interval Time_ns.Span.zero
    then None
    else Some (t.rate *. Time_ns.Span.( // ) eight_hours interval))
;;
