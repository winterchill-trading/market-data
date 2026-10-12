open! Core
open! Async
open Market_data

let print_event e =
  printf
    !"%{Time_ns.to_string_utc} %s\n"
    (Event.recv_ts e)
    (Stream.to_string (Event.stream e))
;;

let%expect_test "event shape" =
  print_endline [%bin_digest: Event.Stable.V1.t];
  [%expect {| 4cf56dfbcb69fbab68b38db7a2944d7b |}];
  return ()
;;

let events : Event.t list =
  [ Trade (Sample.trade ~ms:0 ~price:"100" ~size:"1" ())
  ; Bbo (Sample.bbo ~ms:1 ~bid:"99.9" ~ask:"100.1")
  ; Funding (Sample.funding ~ms:2 ~rate:0.0001)
  ; Trade (Sample.trade ~ms:3 ~price:"100.1" ~size:"2" ())
  ; Bbo (Sample.bbo ~ms:86_400_000 ~bid:"100" ~ask:"100.2")
  ; Trade (Sample.trade ~ms:86_400_005 ~price:"100.2" ~size:"0.5" ())
  ]
;;

let%expect_test "write, list files and merge back" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let files = Event_log.Writer.files w in
    List.iter files ~f:(fun f -> print_endline (Sample.relative ~dir f));
    let%bind merged = Pipe.to_list (Event_log.read_merged files) in
    List.iter merged ~f:print_event;
    printf "round trip: %b\n" (List.equal Event.equal merged events);
    [%expect
      {|
      binance/BTCUSDT/norm/bbo/2026-01-01.bin
      binance/BTCUSDT/norm/bbo/2026-01-02.bin
      binance/BTCUSDT/norm/funding/2026-01-01.bin
      binance/BTCUSDT/norm/trades/2026-01-01.bin
      binance/BTCUSDT/norm/trades/2026-01-02.bin
      2026-01-01 00:00:00.001000000Z trades
      2026-01-01 00:00:00.002000000Z bbo
      2026-01-01 00:00:00.003000000Z funding
      2026-01-01 00:00:00.004000000Z trades
      2026-01-02 00:00:00.001000000Z bbo
      2026-01-02 00:00:00.006000000Z trades
      round trip: true
      |}];
    return ())
;;

let%expect_test "truncated event file" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let path = Event_log.path ~dir Sample.btc Trades (Date.of_string "2026-01-01") in
    let%bind stat = Unix.stat path in
    let%bind () = Unix.truncate path ~len:(Int64.( - ) stat.size 3L) in
    let%map events, tail = Event_log.load_file path in
    printf "%d events\n" (List.length events);
    print_s [%sexp (tail : Framed.Tail.t)];
    [%expect {|
      1 events
      (Truncated (bytes 50))
      |}])
;;
