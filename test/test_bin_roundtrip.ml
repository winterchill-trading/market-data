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
  round_trip "funding v2" (module Funding.Stable.V2);
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
    funding v2
    candle
    event
    frame log record
    |}]
;;

let%expect_test "Event.t writes the bytes of the stable constructor it maps to" =
  let event_gen =
    Quickcheck.Generator.map Event.Stable.V1.quickcheck_generator ~f:Event.of_stable
  in
  Quickcheck.test ~trials:1000 event_gen ~sexp_of:Event.sexp_of_t ~f:(fun e ->
    let bytes = Binable.to_string (module Event) e in
    let stable = Binable.to_string (module Event.Stable.V1) (Event.to_stable e) in
    if not (String.equal bytes stable)
    then raise_s [%message "bytes differ" (e : Event.t)];
    let e' = Binable.of_string (module Event) bytes in
    if Event.compare e e' <> 0
    then raise_s [%message "Event.t round trip failed" (e : Event.t) (e' : Event.t)];
    let e'' = Event.of_stable (Event.to_stable e) in
    if Event.compare e e'' <> 0
    then raise_s [%message "of_stable (to_stable e) <> e" (e : Event.t)]);
  [%expect {| |}]
;;
