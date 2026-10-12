open! Core
open! Async
open Market_data

let events : Event.t list =
  [ Trade (Sample.trade ~ms:0 ~price:"100" ~size:"1" ())
  ; Trade (Sample.trade ~ms:1_000 ~price:"100" ~size:"0" ())
  ; Trade (Sample.trade ~ms:91_000 ~price:"100.5" ~size:"2" ())
  ; Bbo (Sample.bbo ~ms:0 ~bid:"99.9" ~ask:"100.1")
  ; Bbo (Sample.bbo ~ms:30_000 ~bid:"100.2" ~ask:"100.1")
  ; Bbo (Sample.bbo ~ms:200_000 ~bid:"100" ~ask:"100.1")
  ]
;;

let print_report (r : Quality_check.Report.t) =
  List.iter r.checks ~f:(fun c ->
    printf "%-18s %-7s %d\n" c.name (Parquet_kind.to_string c.table) c.violations);
  printf "failed: %d\n%s" (List.length (Quality_check.Report.failed r)) r.gaps
;;

let%expect_test "gaps, non-positive sizes and crossed bbo" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let%bind (_ : Day_close.Result.t list) =
      Day_close.run ~dir (Date.of_string "2026-01-01")
    in
    let%bind () =
      match%map Quality_check.run ~dir () with
      | Ok r -> print_report r
      | Error e -> print_s [%sexp (e : Error.t)]
    in
    [%expect
      {|
      crossed_bbo        bbo     1
      non_positive_size  trades  1
      non_positive_size  bbo     0
      recv_ts_gap        trades  1
      recv_ts_gap        bbo     1
      failed: 4
      table_name,venue,symbol,from_ts,to_ts,gap_ms
      bbo,binance,BTCUSDT,2026-01-01 00:00:30.001,2026-01-01 00:03:20.001,170000.0
      trades,binance,BTCUSDT,2026-01-01 00:00:01.001,2026-01-01 00:01:31.001,90000.0
      |}];
    let%map () =
      match%map Quality_check.run ~max_gap:(Time_ns.Span.of_int_sec 200) ~dir () with
      | Ok r -> print_report r
      | Error e -> print_s [%sexp (e : Error.t)]
    in
    [%expect
      {|
      crossed_bbo        bbo     1
      non_positive_size  trades  1
      non_positive_size  bbo     0
      recv_ts_gap        trades  0
      recv_ts_gap        bbo     0
      failed: 2
      table_name,venue,symbol,from_ts,to_ts,gap_ms
      |}])
;;

let%expect_test "no tables, nothing to check" =
  Sample.with_temp_dir (fun dir ->
    let%map () =
      match%map Quality_check.run ~dir () with
      | Ok r -> print_report r
      | Error e -> print_s [%sexp (e : Error.t)]
    in
    [%expect
      {|
      failed: 0
      table_name,venue,symbol,from_ts,to_ts,gap_ms
      |}])
;;
