open! Core
open Market_data

module type Stable = sig
  type t [@@deriving bin_io, sexp_of, compare, quickcheck]
end

(* [compare] rather than [equal]: it treats NaN funding rates as equal to themselves. *)
let round_trip (type a) name (module M : Stable with type t = a) =
  Quickcheck.test ~trials:500 M.quickcheck_generator ~sexp_of:M.sexp_of_t ~f:(fun v ->
    let s = Binable.to_string (module M) v in
    let v' = Binable.of_string (module M) s in
    if M.compare v v' <> 0
    then raise_s [%message "bin_io round trip failed" name (v : M.t) (v' : M.t)]);
  print_endline name
;;

let%expect_test "every stable type survives a bin_io round trip" =
  round_trip "venue" (module Venue.Stable.V1);
  round_trip "side" (module Side.Stable.V1);
  round_trip "symbol" (module Symbol.Stable.V1);
  round_trip "price" (module Price.Stable.V1);
  round_trip "size" (module Size.Stable.V1);
  round_trip "instrument" (module Instrument.Stable.V1);
  round_trip "trade" (module Trade.Stable.V1);
  round_trip "bbo" (module Bbo.Stable.V1);
  round_trip "l2 level" (module L2_update.Level.Stable.V1);
  round_trip "l2 kind" (module L2_update.Kind.Stable.V1);
  round_trip "l2 update" (module L2_update.Stable.V1);
  round_trip "funding" (module Funding.Stable.V1);
  round_trip "candle" (module Candle.Stable.V1);
  round_trip "event" (module Event.Stable.V1);
  round_trip "frame log record" (module Frame_log.Record.Stable.V1);
  [%expect
    {|
    venue
    side
    symbol
    price
    size
    instrument
    trade
    bbo
    l2 level
    l2 kind
    l2 update
    funding
    candle
    event
    frame log record
    |}]
;;
