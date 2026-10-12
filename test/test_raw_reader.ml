open! Core
open! Async
open Market_data

let save ~dir path contents =
  let path = dir ^/ "raw" ^/ path in
  let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
  Writer.save path ~contents
;;

(* Trades span midnight in compressed files; bbo has a disconnect and a bad line. *)
let write_raw ~dir =
  let%bind () =
    save
      ~dir
      "binance/trades/BTC_USDT/2026/01/01/23-59.ndjson.zst"
      (Zstd.compress
         ~level:3
         "2026-01-01T23:59:10.000000Z t1\n2026-01-01T23:59:50.000000Z t2\n")
  in
  let%bind () =
    save
      ~dir
      "binance/trades/BTC_USDT/2026/01/02/00-00.ndjson.zst"
      (Zstd.compress ~level:3 "2026-01-02T00:00:20.000000Z t3\n"
       ^ Zstd.compress ~level:3 "2026-01-02T00:00:40.000000Z t4\n")
  in
  let%bind () =
    save
      ~dir
      "binance/bbo/BTC_USDT/2026/01/01/23-59.ndjson"
      "2026-01-01T23:59:10.000000Z b1\n\n2026-01-01T23:59:30.000000Z b2\nbroken\n"
  in
  let%bind () =
    save
      ~dir
      "binance/bbo/BTC_USDT/2026/01/02/00-00.ndjson"
      "\n2026-01-02T00:00:30.000000Z b3\n"
  in
  (* Another symbol and another venue are not read. *)
  let%bind () =
    save
      ~dir
      "binance/trades/ETHUSDT/2026/01/01/23-59.ndjson"
      "2026-01-01T23:59:11.000000Z x\n"
  in
  save
    ~dir
    "bybit/trades/BTC_USDT/2026/01/01/23-59.ndjson"
    "2026-01-01T23:59:11.000000Z y\n"
;;

let print_items ?streams ~dir ~start ~stop () =
  let errors = ref [] in
  let%map items =
    Raw_reader.read
      ?streams
      ~on_error:(fun e -> errors := e :: !errors)
      ~data_dir:dir
      ~venue:Binance
      ~symbol:"BTC/USDT"
      ~start:(Time_ns.of_string_with_utc_offset start)
      ~stop:(Time_ns.of_string_with_utc_offset stop)
      ()
    |> Pipe.to_list
  in
  List.iter items ~f:(fun item -> print_s [%sexp (item : Raw_reader.Item.t)]);
  List.iter (List.rev !errors) ~f:(fun e ->
    Error.to_string_hum e
    |> String.substr_replace_all ~pattern:(dir ^ "/") ~with_:""
    |> print_endline)
;;

let%expect_test "streams merged by recv_ts across a day boundary" =
  Sample.with_temp_dir (fun dir ->
    let%bind () = write_raw ~dir in
    let%bind streams =
      Raw_reader.streams ~data_dir:dir ~venue:Binance ~symbol:"BTC/USDT"
    in
    print_s [%sexp (streams : Stream.t list)];
    [%expect {| (Trades Bbo) |}];
    let%bind () =
      print_items ~dir ~start:"2026-01-01T23:00:00Z" ~stop:"2026-01-02T01:00:00Z" ()
    in
    [%expect
      {|
      (Frame (recv_ts "2026-01-01 23:59:10Z") (stream Trades) (frame t1))
      (Frame (recv_ts "2026-01-01 23:59:10Z") (stream Bbo) (frame b1))
      (Gap (recv_ts "2026-01-01 23:59:10Z") (stream Bbo))
      (Frame (recv_ts "2026-01-01 23:59:30Z") (stream Bbo) (frame b2))
      (Frame (recv_ts "2026-01-01 23:59:50Z") (stream Trades) (frame t2))
      (Gap (recv_ts "2026-01-02 00:00:00Z") (stream Bbo))
      (Frame (recv_ts "2026-01-02 00:00:20Z") (stream Trades) (frame t3))
      (Frame (recv_ts "2026-01-02 00:00:30Z") (stream Bbo) (frame b3))
      (Frame (recv_ts "2026-01-02 00:00:40Z") (stream Trades) (frame t4))
      (raw/binance/bbo/BTC_USDT/2026/01/01/23-59.ndjson
       ("Raw_minute: no space after the timestamp" broken))
      |}];
    (* The range cuts frames and gaps by recv_ts; only overlapping minutes are read. *)
    let%bind () =
      print_items
        ~streams:[ Trades; Bbo ]
        ~dir
        ~start:"2026-01-01T23:59:30Z"
        ~stop:"2026-01-02T00:00:30Z"
        ()
    in
    [%expect
      {|
      (Frame (recv_ts "2026-01-01 23:59:30Z") (stream Bbo) (frame b2))
      (Frame (recv_ts "2026-01-01 23:59:50Z") (stream Trades) (frame t2))
      (Gap (recv_ts "2026-01-02 00:00:00Z") (stream Bbo))
      (Frame (recv_ts "2026-01-02 00:00:20Z") (stream Trades) (frame t3))
      (raw/binance/bbo/BTC_USDT/2026/01/01/23-59.ndjson
       ("Raw_minute: no space after the timestamp" broken))
      |}];
    let%bind () =
      print_items ~dir ~start:"2026-01-02T00:01:00Z" ~stop:"2026-01-03T00:00:00Z" ()
    in
    [%expect {| |}];
    return ())
;;

let%expect_test "closing the output early stops reading" =
  Sample.with_temp_dir (fun dir ->
    let%bind () = write_raw ~dir in
    let r =
      Raw_reader.read
        ~on_error:ignore
        ~data_dir:dir
        ~venue:Binance
        ~symbol:"BTC/USDT"
        ~start:(Time_ns.of_string_with_utc_offset "2026-01-01T00:00:00Z")
        ~stop:(Time_ns.of_string_with_utc_offset "2026-01-03T00:00:00Z")
        ()
    in
    let%bind first = Pipe.read r in
    print_s [%sexp (first : [ `Eof | `Ok of Raw_reader.Item.t ])];
    Pipe.close_read r;
    [%expect
      {| (Ok (Frame (recv_ts "2026-01-01 23:59:10Z") (stream Trades) (frame t1))) |}];
    return ())
;;
