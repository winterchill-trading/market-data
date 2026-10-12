open! Core
open! Async
open Market_data

let print_records records =
  List.iter records ~f:(fun (r : Frame_log.Record.t) ->
    printf !"%{Time_ns.to_string_utc} #%d %s\n" r.recv_ts r.stream_id r.payload)
;;

let%expect_test "record shape" =
  print_endline [%bin_digest: Frame_log.Record.Stable.V1.t];
  [%expect {| e49e60d7b3fcee2c9c4c276d753deffc |}];
  return ()
;;

let%expect_test "daily rotation and read back" =
  Sample.with_temp_dir (fun dir ->
    let w = Frame_log.Writer.create ~dir Sample.btc Trades in
    List.iteri [ 0; 1_000; 86_399_999; 86_400_000; 86_400_500 ] ~f:(fun i ms ->
      Frame_log.Writer.write w ~recv_ts:(Sample.ts ms) ~stream_id:7 (sprintf "msg-%d" i));
    let%bind () = Frame_log.Writer.close w in
    let files = Frame_log.Writer.files w in
    let%bind () =
      Deferred.List.iter ~how:`Sequential files ~f:(fun path ->
        let%map records, tail = Frame_log.load_file path in
        print_endline (Sample.relative ~dir path);
        print_records records;
        print_s [%sexp (tail : Framed.Tail.t)])
    in
    [%expect
      {|
      binance/BTCUSDT/raw/trades/2026-01-01.binlog
      2026-01-01 00:00:00.000000000Z #7 msg-0
      2026-01-01 00:00:01.000000000Z #7 msg-1
      2026-01-01 23:59:59.999000000Z #7 msg-2
      Clean
      binance/BTCUSDT/raw/trades/2026-01-02.binlog
      2026-01-02 00:00:00.000000000Z #7 msg-3
      2026-01-02 00:00:00.500000000Z #7 msg-4
      Clean
      |}];
    return ())
;;
