open! Core
open! Async
open Market_data

let eth = Instrument.create Binance "ETHUSDT"

let%expect_test "events of several instruments; unconfigured ones are skipped" =
  let trades =
    List.init 40 ~f:(fun i ->
      let t =
        Sample.trade
          ~side:(if i % 3 = 0 then Sell else Buy)
          ~ms:i
          ~price:"100"
          ~size:"1"
          ()
      in
      if i % 2 = 0 then t else { t with instrument = eth })
  in
  let config instrument =
    if Instrument.equal instrument Sample.btc
    then Some (Toxicity.Config.default ~bucket_volume:(Size.of_string "5"))
    else None
  in
  let%bind events =
    Toxicity_feed.of_trades ~config (Pipe.of_list trades) |> Pipe.to_list
  in
  List.iter events ~f:(fun (e : Toxicity.Event.t) ->
    printf
      "%s bucket %d buy %.0f sell %.0f vpin %.3f\n"
      (Instrument.to_string e.instrument)
      e.bucket
      e.buy_volume
      e.sell_volume
      e.vpin);
  [%expect
    {|
    binance:BTCUSDT bucket 0 buy 3 sell 2 vpin 0.200
    binance:BTCUSDT bucket 1 buy 3 sell 2 vpin 0.200
    binance:BTCUSDT bucket 2 buy 4 sell 1 vpin 0.333
    binance:BTCUSDT bucket 3 buy 3 sell 2 vpin 0.300
    |}];
  return ()
;;

let%expect_test "a replayed feed: the research fixture's Binance trades" =
  let feed =
    Replay_feed.of_files
      ~speed:0.
      [ "fixtures/event-log-research/binance/BTCUSDT/norm/trades/2026-01-01.bin" ]
  in
  let (module F) = feed in
  let config _ =
    Some
      { (Toxicity.Config.default ~bucket_volume:(Size.of_string "20")) with window = 3 }
  in
  let%bind events = Toxicity_feed.of_feed ~config feed |> Pipe.to_list in
  let%bind () = F.close () in
  printf "%d buckets\n" (List.length events);
  List.iter (List.take events 4) ~f:(fun e ->
    printf
      "bucket %d imbalance %+.3f vpin %.3f dominant %s\n"
      e.bucket
      e.imbalance
      e.vpin
      (Option.value_map e.dominant ~default:"-" ~f:(fun s ->
         Sexp.to_string (Side.sexp_of_t s))));
  [%expect
    {|
    3 buckets
    bucket 0 imbalance +0.060 vpin 0.060 dominant Buy
    bucket 1 imbalance -0.301 vpin 0.180 dominant Sell
    bucket 2 imbalance +0.148 vpin 0.170 dominant Buy
    |}];
  return ()
;;
