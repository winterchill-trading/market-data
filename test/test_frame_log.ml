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

let write_three dir =
  let w = Frame_log.Writer.create ~dir Sample.btc Bbo in
  List.iter [ 1; 2; 3 ] ~f:(fun i ->
    Frame_log.Writer.write w ~recv_ts:(Sample.ts i) ~stream_id:1 (sprintf "payload-%d" i));
  let%map () = Frame_log.Writer.close w in
  List.hd_exn (Frame_log.Writer.files w)
;;

let file_size path =
  let%map stat = Unix.stat path in
  Int64.to_int_exn stat.size
;;

let%expect_test "crash safety: a truncated tail is dropped" =
  Sample.with_temp_dir (fun dir ->
    let%bind path = write_three dir in
    let%bind size = file_size path in
    printf "file size %d\n" size;
    let%bind () =
      Deferred.List.iter ~how:`Sequential [ 1; 10; 22; 26 ] ~f:(fun cut ->
        let%bind path = write_three (dir ^/ Int.to_string cut) in
        let%bind () = Unix.truncate path ~len:(Int64.of_int (size - cut)) in
        let%map records, tail = Frame_log.load_file path in
        printf "cut %d bytes: " cut;
        print_s
          [%message
            ""
              ~payloads:(List.map records ~f:Frame_log.Record.payload : string list)
              (tail : Framed.Tail.t)])
    in
    [%expect
      {|
      file size 84
      cut 1 bytes: ((payloads (payload-1 payload-2)) (tail (Truncated (bytes 27))))
      cut 10 bytes: ((payloads (payload-1 payload-2)) (tail (Truncated (bytes 18))))
      cut 22 bytes: ((payloads (payload-1 payload-2)) (tail (Truncated (bytes 6))))
      cut 26 bytes: ((payloads (payload-1 payload-2)) (tail (Truncated (bytes 2))))
      |}];
    return ())
;;

let%expect_test "crash safety: reopening repairs the tail before appending" =
  Sample.with_temp_dir (fun dir ->
    let%bind path = write_three dir in
    let%bind size = file_size path in
    let%bind () = Unix.truncate path ~len:(Int64.of_int (size - 5)) in
    let w = Frame_log.Writer.create ~dir Sample.btc Bbo in
    Frame_log.Writer.write w ~recv_ts:(Sample.ts 4) ~stream_id:1 "after-restart";
    let%bind () = Frame_log.Writer.close w in
    let%map records, tail = Frame_log.load_file path in
    print_s
      [%message
        ""
          ~payloads:(List.map records ~f:Frame_log.Record.payload : string list)
          (tail : Framed.Tail.t)];
    [%expect {| ((payloads (payload-1 payload-2 after-restart)) (tail Clean)) |}])
;;

(* Deterministic on purpose. An earlier version slept 200ms on the wall clock and checked
   that the file did not exist right after a write crossing [flush_bytes]; that size flush
   is started inside [write], so on a fast Linux runner the file could already exist when
   the check ran. Now the interval timer runs on a synthetic time source, each trigger is
   observed through [buffered_bytes] (which drops to 0 the moment a flush takes the
   buffer), and [flush] on an empty buffer only waits for that in-flight write. *)
let%expect_test "flush policy: by time and by size" =
  Sample.with_temp_dir (fun dir ->
    let ms = Time_ns.Span.of_int_ms in
    let path = Frame_log.path ~dir Sample.btc L2 (Date.of_string "2026-01-01") in
    let on_disk () =
      match%map Monitor.try_with (fun () -> file_size path) with
      | Ok n -> Int.to_string n
      | Error _ -> "missing"
    in
    let start ~flush_interval ~flush_bytes payload =
      let%map () = Process.run_expect_no_stdout_exn ~prog:"rm" ~args:[ "-f"; path ] () in
      let time_source = Time_source.create ~now:(Sample.ts 0) () in
      let w =
        Frame_log.Writer.create
          ~flush_interval
          ~flush_bytes
          ~time_source:(Time_source.read_only time_source)
          ~dir
          Sample.btc
          L2
      in
      Frame_log.Writer.write w ~recv_ts:(Sample.ts 0) ~stream_id:0 payload;
      print_s [%message "written" ~buffered:(Frame_log.Writer.buffered_bytes w : int)];
      time_source, w
    in
    let advance time_source w span =
      let%map () = Time_source.advance_by_alarms_by time_source span in
      print_s
        [%message
          "advanced"
            (span : Time_ns.Span.t)
            ~buffered:(Frame_log.Writer.buffered_bytes w : int)]
    in
    let flushed w =
      let%bind () = Frame_log.Writer.flush w in
      let%bind file = on_disk () in
      print_s [%message (file : string)];
      Frame_log.Writer.close w
    in
    (* timer flush: tiny record, large size threshold, 50ms interval *)
    let%bind ts, w = start ~flush_interval:(ms 50) ~flush_bytes:1_000_000 "small" in
    let%bind () = advance ts w (ms 49) in
    let%bind () = advance ts w (ms 1) in
    let%bind () = flushed w in
    [%expect
      {|
      (written (buffered 24))
      (advanced (span 49ms) (buffered 24))
      (advanced (span 1ms) (buffered 0))
      (file 24)
      |}];
    (* size flush: interval far away, record over the threshold *)
    let%bind _, w =
      start ~flush_interval:Time_ns.Span.hour ~flush_bytes:100 (String.make 100 'x')
    in
    let%bind () = flushed w in
    [%expect {|
      (written (buffered 0))
      (file 119)
      |}];
    (* neither: nothing reaches the file before close *)
    let%bind ts, w =
      start ~flush_interval:Time_ns.Span.hour ~flush_bytes:1_000_000 "small"
    in
    let%bind () = advance ts w (Time_ns.Span.of_min 59.) in
    let%bind file = on_disk () in
    print_s [%message (file : string)];
    let%bind () = Frame_log.Writer.close w in
    let%map file = on_disk () in
    print_s [%message "closed" (file : string)];
    [%expect
      {|
      (written (buffered 24))
      (advanced (span 59m) (buffered 24))
      (file missing)
      (closed (file 24))
      |}])
;;

let%expect_test "merged read across streams orders by recv_ts" =
  Sample.with_temp_dir (fun dir ->
    let trades = Frame_log.Writer.create ~dir Sample.btc Trades in
    let bbo = Frame_log.Writer.create ~dir Sample.btc Bbo in
    List.iter
      [ 0, trades; 5, bbo; 5, trades; 7, bbo; 9, trades ]
      ~f:(fun (ms, w) ->
        let stream_id = if phys_equal w trades then 1 else 2 in
        Frame_log.Writer.write w ~recv_ts:(Sample.ts ms) ~stream_id (sprintf "at-%d" ms));
    let%bind () = Frame_log.Writer.close trades in
    let%bind () = Frame_log.Writer.close bbo in
    let%map records =
      Pipe.to_list
        (Frame_log.read_merged
           (Frame_log.Writer.files trades @ Frame_log.Writer.files bbo))
    in
    print_records records;
    [%expect
      {|
      2026-01-01 00:00:00.000000000Z #1 at-0
      2026-01-01 00:00:00.005000000Z #1 at-5
      2026-01-01 00:00:00.005000000Z #2 at-5
      2026-01-01 00:00:00.007000000Z #2 at-7
      2026-01-01 00:00:00.009000000Z #1 at-9
      |}])
;;
