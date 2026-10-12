open! Core
open! Async
open Market_data

(* In the fixture every venue quotes the same mid path, received 5 ms (Binance), 45 ms
   (Bybit) and 125 ms (Hyperliquid) after each step, plus or minus 10 ms; steps are 1.3 s
   to 1.7 s apart, longer than the query's 1 s window. *)
let%expect_test "lead-lag recovers the planted lags" =
  Sample.with_temp_dir (fun dir ->
    let%bind () =
      Process.run_expect_no_stdout_exn
        ~prog:"cp"
        ~args:[ "-RL"; "fixtures/event-log-research/."; dir ]
        ()
    in
    let%bind (_ : Day_close.Result.t list) =
      Day_close.run ~dir (Date.of_string "2026-01-01")
    in
    let%bind sql = Reader.file_contents "../queries/lead_lag.sql" in
    let%bind () =
      match%map Parquet_views.query ~format:Csv ~dir sql with
      | Ok out -> print_string out
      | Error e -> print_s [%sexp (e : Error.t)]
    in
    [%expect
      {|
      token,leader,follower,leader_changes,matched,matched_share,median_lag_ms,p25_ms,p75_ms
      BTC,binance,bybit,399,399,1.0,40.0,34.0,46.0
      BTC,bybit,hyperliquid,399,399,1.0,80.0,74.0,85.0
      BTC,binance,hyperliquid,399,399,1.0,120.0,115.0,126.0
      BTC,bybit,binance,399,0,0.0,NULL,NULL,NULL
      BTC,hyperliquid,binance,399,0,0.0,NULL,NULL,NULL
      BTC,hyperliquid,bybit,399,0,0.0,NULL,NULL,NULL
      |}];
    return ())
;;
