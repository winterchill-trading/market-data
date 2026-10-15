(* core_bench cases for the per-trade feature folds: one [add] per run, cycling through a
   prebuilt tape so that bars, events and buckets close at a realistic rate. *)

open! Core
open Market_data
open Core_bench

let instrument = Instrument.create Binance "BTCUSDT"
let epoch = Time_ns.of_string_with_utc_offset "2026-01-01 00:00:00Z"

(* 100k trades: a random walk of one-dollar ticks around 100k, sizes 0.001 to 0.5, about
   ten trades a second, sides from the step. *)
let tape =
  let rng = Random.State.make [| 42 |] in
  let price = ref 100_000 in
  Array.init 100_000 ~f:(fun i ->
    let up = Random.State.bool rng in
    price := !price + if up then 1 else -1;
    { Trade.instrument
    ; exch_ts = Time_ns.add epoch (Time_ns.Span.of_int_ms (i * 100))
    ; recv_ts = Time_ns.add epoch (Time_ns.Span.of_int_ms ((i * 100) + 1))
    ; price = Price.of_int !price
    ; size = Size.of_units (100_000 * (1 + Random.State.int rng 500))
    ; side = (if up then Buy else Sell)
    ; trade_id = Int.to_string i
    })
;;

let cycle f =
  let i = ref 0 in
  fun () ->
    f tape.(!i);
    i := if !i = Array.length tape - 1 then 0 else !i + 1
;;

let bars spec =
  let t = Bars.create instrument spec in
  Bench.Test.create
    ~name:("Bars.add " ^ Bars.Spec.to_string spec)
    (cycle (fun trade -> ignore (Bars.add t trade : _ or_null)))
;;

let toxicity classification =
  let t =
    Toxicity.create
      instrument
      { (Toxicity.Config.default ~bucket_volume:(Size.of_int 50)) with classification }
  in
  Bench.Test.create
    ~name:("Toxicity.add " ^ Toxicity.Classification.to_string classification)
    (cycle (fun trade -> ignore (Toxicity.add t trade : Toxicity.Event.t list)))
;;

let () =
  let adaptive = Bars.Adaptive.default ~warmup_ticks:100 in
  let dc = Directional_change.create ~theta:0.0005 in
  let cusum = Cusum_filter.create ~threshold:0.0005 in
  Command_unix.run
    (Bench.make_command
       [ bars (Tick 1000)
       ; bars (Volume (Size.of_int 50))
       ; bars (Dollar 5_000_000.)
       ; bars (Imbalance (Dollar, adaptive))
       ; bars (Run (Volume, adaptive))
       ; Bench.Test.create
           ~name:"Directional_change.add_trade"
           (cycle (fun trade ->
              ignore (Directional_change.add_trade dc trade : _ or_null)))
       ; Bench.Test.create
           ~name:"Cusum_filter.add_trade"
           (cycle (fun trade -> ignore (Cusum_filter.add_trade cusum trade : _ or_null)))
       ; toxicity Aggressor
       ; toxicity Tick_rule
       ; toxicity (Bulk { interval = Time_ns.Span.minute; span = 20 })
       ])
;;
