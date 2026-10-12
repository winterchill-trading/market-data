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
  [%expect {| cdf98830f211bb2d1384927d19dab635 |}];
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

let print_failure ~dir f =
  match%map Monitor.try_with ~extract_exn:true f with
  | Ok _ -> print_endline "no error"
  | Error exn ->
    Exn.to_string_mach exn
    |> String.substr_replace_all ~pattern:dir ~with_:"$DIR"
    |> print_endline
;;

let%expect_test "files start with the event digest" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let path = Event_log.path ~dir Sample.btc Trades (Date.of_string "2026-01-01") in
    let%bind digest = Framed.read_digest path in
    let%bind prefix =
      Reader.with_file path ~f:(fun r -> Reader.peek r ~len:Framed.File_header.length)
    in
    print_s [%sexp (prefix : string Reader.Read_result.t)];
    printf
      "matches Event_log.digest: %b\n"
      ([%equal: string option] digest (Some Event_log.digest));
    [%expect
      {|
      (Ok MDFRAME1cdf98830f211bb2d1384927d19dab635)
      matches Event_log.digest: true
      |}];
    return ())
;;

let%expect_test "a file of another record type fails clearly" =
  Sample.with_temp_dir (fun dir ->
    let path = Event_log.path ~dir Sample.btc Trades (Date.of_string "2026-01-01") in
    let other_digest =
      Bin_prot.Shape.eval_to_digest_string Frame_log.Record.Stable.V1.bin_shape_t
    in
    let w =
      Framed.Writer.create
        ~digest:other_digest
        Frame_log.Record.bin_writer_t
        ~path_for_date:(fun _ -> path)
        ()
    in
    Framed.Writer.append
      w
      { recv_ts = Sample.ts 0; stream_id = 1; payload = "{}" }
      ~time:(Sample.ts 0);
    let%bind () = Framed.Writer.close w in
    let%bind () = print_failure ~dir (fun () -> Event_log.load_file path) in
    [%expect
      {| ("bin_shape digest mismatch: the file was written with a record type not known to be compatible"(path $DIR/binance/BTCUSDT/norm/trades/2026-01-01.bin)(found e49e60d7b3fcee2c9c4c276d753deffc)(accepted(cdf98830f211bb2d1384927d19dab635 2f7f1bcba79db3ddd1b04d266342a8af 4cf56dfbcb69fbab68b38db7a2944d7b))) |}];
    let%bind () =
      print_failure ~dir (fun () -> Pipe.to_list (Event_log.read_merged [ path ]))
    in
    [%expect
      {| ("bin_shape digest mismatch: the file was written with a record type not known to be compatible"(path $DIR/binance/BTCUSDT/norm/trades/2026-01-01.bin)(found e49e60d7b3fcee2c9c4c276d753deffc)(accepted(cdf98830f211bb2d1384927d19dab635 2f7f1bcba79db3ddd1b04d266342a8af 4cf56dfbcb69fbab68b38db7a2944d7b))) |}];
    let w = Event_log.Writer.create ~dir () in
    let%bind () =
      print_failure ~dir (fun () ->
        Event_log.Writer.append w (List.hd_exn events);
        Event_log.Writer.close w)
    in
    [%expect
      {| ("bin_shape digest mismatch: the file was written with a record type not known to be compatible"(path $DIR/binance/BTCUSDT/norm/trades/2026-01-01.bin)(found e49e60d7b3fcee2c9c4c276d753deffc)(accepted(cdf98830f211bb2d1384927d19dab635 2f7f1bcba79db3ddd1b04d266342a8af 4cf56dfbcb69fbab68b38db7a2944d7b))) |}];
    return ())
;;

let%expect_test "files without a header still read" =
  Sample.with_temp_dir (fun dir ->
    let path = Event_log.path ~dir Sample.btc Trades (Date.of_string "2026-01-01") in
    let w = Framed.Writer.create Event.bin_writer_t ~path_for_date:(fun _ -> path) () in
    List.iter events ~f:(fun e -> Framed.Writer.append w e ~time:(Sample.ts 0));
    let%bind () = Framed.Writer.close w in
    let%bind digest = Framed.read_digest path in
    let%bind loaded, tail = Event_log.load_file path in
    print_s
      [%message
        (digest : string option) ~events:(List.length loaded : int) (tail : Framed.Tail.t)];
    [%expect {| ((digest ()) (events 6) (tail Clean)) |}];
    (* A new writer continues the old file without adding a header in the middle. *)
    let w = Event_log.Writer.create ~dir () in
    Event_log.Writer.append w (List.hd_exn events);
    let%bind () = Event_log.Writer.close w in
    let%bind loaded, tail = Event_log.load_file path in
    print_s [%message "" ~events:(List.length loaded : int) (tail : Framed.Tail.t)];
    [%expect {| ((events 7) (tail Clean)) |}];
    return ())
;;
