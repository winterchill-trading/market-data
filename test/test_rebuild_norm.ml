open! Core
open! Async
open Market_data

(* A toy venue: frames are ["trade <price> <size> <id>"], ["ack"] or garbage. *)
module Toy : Normalizer.S = struct
  type t = { mutable connection : int }

  let venue = Venue.Binance
  let create () = { connection = 0 }

  let frame t ~recv_ts payload =
    match String.split payload ~on:' ' with
    | [ "ack" ] -> Ok []
    | [ "trade"; price; size; id ] ->
      Ok
        [ Event.Trade
            { instrument = Sample.btc
            ; exch_ts = recv_ts
            ; recv_ts
            ; price = Price.of_string price
            ; size = Size.of_string size
            ; side = Buy
            ; trade_id = sprintf "%d/%s" t.connection id
            }
        ]
    | _ -> Or_error.error_s [%message "toy: unknown frame" payload]
  ;;

  let disconnect t = t.connection <- t.connection + 1
end

let%expect_test "lines and paths" =
  List.iter
    [ "2026-01-01T00:00:01.000002Z {\"a\":1}"; ""; "2026-01-01T00:00:01Z"; "nonsense" ]
    ~f:(fun line ->
      print_s [%sexp (Raw_minute.Line.parse line : Raw_minute.Line.t Or_error.t)]);
  List.iter
    [ "/d/raw/kraken/l2/BTC_USD/2026/01/01/23-59.ndjson.zst"
    ; "raw/okx/funding/BTC-USDT-SWAP/2026/01/01/00-07.ndjson"
    ; "raw/okx/funding/BTC-USDT-SWAP/2026/01/01/upload.sexp"
    ]
    ~f:(fun path ->
      print_s [%sexp (Raw_minute.File.of_path path : Raw_minute.File.t Or_error.t)]);
  [%expect
    {|
    (Ok (Frame (recv_ts "2026-01-01 00:00:01.000002Z") (payload "{\"a\":1}")))
    (Ok Disconnect)
    (Error ("Raw_minute: no space after the timestamp" 2026-01-01T00:00:01Z))
    (Error ("Raw_minute: no space after the timestamp" nonsense))
    (Ok
     ((venue Kraken) (stream L2) (symbol_dir BTC_USD)
      (minute "2026-01-01 23:59:00Z") (compressed true)
      (path /d/raw/kraken/l2/BTC_USD/2026/01/01/23-59.ndjson.zst)))
    (Ok
     ((venue Okx) (stream Funding) (symbol_dir BTC-USDT-SWAP)
      (minute "2026-01-01 00:07:00Z") (compressed false)
      (path raw/okx/funding/BTC-USDT-SWAP/2026/01/01/00-07.ndjson)))
    (Error
     (("Raw_minute: not a minute file"
       raw/okx/funding/BTC-USDT-SWAP/2026/01/01/upload.sexp)
      (Invalid_argument "String.chop_suffix_exn \"upload.sexp\" \".ndjson\"")))
    |}];
  return ()
;;

let write_raw ~dir =
  let day = dir ^/ "raw/binance/trades/BTCUSDT/2026/01/01" in
  let%bind () = Unix.mkdir ~p:() day in
  (* A restart within the minute appends a second zstd frame. *)
  let zst =
    Zstd.compress
      ~level:3
      "2026-01-01T00:00:01.000000Z ack\n2026-01-01T00:00:02.000000Z trade 100 1 a\n"
    ^ Zstd.compress ~level:3 "2026-01-01T00:00:30.500000Z trade 101 2 b\n"
  in
  let%bind () = Writer.save (day ^/ "00-00.ndjson.zst") ~contents:zst in
  let%bind () =
    Writer.save
      (day ^/ "00-01.ndjson")
      ~contents:
        "2026-01-01T00:01:00.000000Z bogus\n\n2026-01-01T00:01:05.000000Z trade 102 3 c\n"
  in
  let other = dir ^/ "raw/bybit/trades/BTCUSDT/2026/01/01" in
  let%bind () = Unix.mkdir ~p:() other in
  Writer.save (other ^/ "00-00.ndjson") ~contents:"2026-01-01T00:00:01.000000Z x\n"
;;

let%expect_test "rebuild a day with an inline normalizer" =
  Sample.with_temp_dir (fun dir ->
    let%bind () = write_raw ~dir in
    let date = Date.of_string "2026-01-01" in
    let%bind files = Raw_minute.files ~data_dir:dir date in
    List.iter files ~f:(fun (f : Raw_minute.File.t) ->
      print_endline (Sample.relative ~dir f.path));
    let%bind lines = Raw_minute.read (List.hd_exn files).path in
    print_s [%sexp (lines : Raw_minute.Line.t list Or_error.t)];
    [%expect
      {|
      raw/binance/trades/BTCUSDT/2026/01/01/00-00.ndjson.zst
      raw/binance/trades/BTCUSDT/2026/01/01/00-01.ndjson
      raw/bybit/trades/BTCUSDT/2026/01/01/00-00.ndjson
      (Ok
       ((Frame (recv_ts "2026-01-01 00:00:01Z") (payload ack))
        (Frame (recv_ts "2026-01-01 00:00:02Z") (payload "trade 100 1 a"))
        (Frame (recv_ts "2026-01-01 00:00:30.5Z") (payload "trade 101 2 b"))))
      |}];
    let out_dir = dir ^/ "rebuilt" in
    let%bind stats =
      Rebuild_norm.run ~normalizers:[ (module Toy) ] ~data_dir:dir ~out_dir date
    in
    print_s [%sexp (stats : Rebuild_norm.Stats.t Or_error.t)];
    let%bind events, tail =
      Event_log.load_file (Event_log.path ~dir:out_dir Sample.btc Trades date)
    in
    List.iter events ~f:(fun e -> print_s [%sexp (e : Event.t)]);
    print_s [%sexp (tail : Framed.Tail.t)];
    [%expect
      {|
      (Ok
       ((files 3) (frames 5) (disconnects 1) (events 3) (frame_errors 1)
        (first_errors
         (((file raw/binance/trades/BTCUSDT/2026/01/01/00-01.ndjson)
           ("toy: unknown frame" bogus))))
        (skipped_files 1) (skipped_venues (Bybit))))
      (Trade
       ((instrument ((venue Binance) (symbol BTCUSDT)))
        (exch_ts (2026-01-01 00:00:02.000000000Z))
        (recv_ts (2026-01-01 00:00:02.000000000Z)) (price 100) (size 1) (side Buy)
        (trade_id 0/a)))
      (Trade
       ((instrument ((venue Binance) (symbol BTCUSDT)))
        (exch_ts (2026-01-01 00:00:30.500000000Z))
        (recv_ts (2026-01-01 00:00:30.500000000Z)) (price 101) (size 2) (side Buy)
        (trade_id 0/b)))
      (Trade
       ((instrument ((venue Binance) (symbol BTCUSDT)))
        (exch_ts (2026-01-01 00:01:05.000000000Z))
        (recv_ts (2026-01-01 00:01:05.000000000Z)) (price 102) (size 3) (side Buy)
        (trade_id 1/c)))
      Clean
      |}];
    let%map again =
      Rebuild_norm.run ~normalizers:[ (module Toy) ] ~data_dir:dir ~out_dir date
    in
    print_s [%sexp (Result.is_error again : bool)];
    [%expect {| true |}])
;;
