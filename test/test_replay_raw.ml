open! Core
open! Async
open Market_data

(* Frames are ["<price>"] trades or ["quote <bid> <ask>"]; the trade id counts connections
   so a disconnect shows. *)
module Toy : Normalizer.S = struct
  type t = { mutable connection : int }

  let venue = Venue.Binance
  let create () = { connection = 0 }

  let frame t ~recv_ts payload =
    match String.split payload ~on:' ' with
    | [ "quote"; bid; ask ] ->
      Ok
        [ Event.Bbo
            { instrument = Sample.btc
            ; exch_ts = recv_ts
            ; recv_ts
            ; bid_price = Price.of_string bid
            ; bid_size = Size.of_string "1"
            ; ask_price = Price.of_string ask
            ; ask_size = Size.of_string "1"
            }
        ]
    | [ price ] when not (String.equal price "bad") ->
      Ok
        [ Event.Trade
            { instrument = Sample.btc
            ; exch_ts = recv_ts
            ; recv_ts
            ; price = Price.of_string price
            ; size = Size.of_string "1"
            ; side = Buy
            ; trade_id = Int.to_string t.connection
            }
        ]
    | _ -> Or_error.error_s [%message "toy: unknown frame" payload]
  ;;

  let disconnect t = t.connection <- t.connection + 1
end

let save ~dir path contents =
  let path = dir ^/ "raw/binance" ^/ path in
  let%bind () = Unix.mkdir ~p:() (Filename.dirname path) in
  Writer.save path ~contents
;;

let%expect_test "raw files replayed through a normalizer, disconnects as gaps" =
  Sample.with_temp_dir (fun dir ->
    let%bind () =
      save
        ~dir
        "trades/BTCUSDT/2026/01/01/00-00.ndjson.zst"
        (Zstd.compress
           ~level:3
           "2026-01-01T00:00:01.000000Z 100\n\
            2026-01-01T00:00:03.000000Z bad\n\n\
            2026-01-01T00:00:05.000000Z 101\n")
    in
    let%bind () =
      save
        ~dir
        "bbo/BTCUSDT/2026/01/01/00-00.ndjson"
        "2026-01-01T00:00:02.000000Z quote 99 100\n"
    in
    let errors = ref 0 in
    let (module F : Feed.With_gaps.S) =
      Replay_feed.of_raw
        ~speed:0.
        ~on_error:(fun _ -> incr errors)
        ~normalizer:(module Toy)
        ~data_dir:dir
        ~symbol:"BTCUSDT"
        ~start:(Time_ns.of_string_with_utc_offset "2026-01-01T00:00:00Z")
        ~stop:(Time_ns.of_string_with_utc_offset "2026-01-01T00:01:00Z")
        ()
    in
    let%map trades = Pipe.to_list F.trades
    and bbo = Pipe.to_list F.bbo
    and l2 = Pipe.to_list F.l2
    and funding = Pipe.to_list F.funding
    and gaps = Pipe.to_list F.gaps in
    print_s
      [%message
        ""
          ~trades:
            (List.map trades ~f:(fun t -> t.price, t.trade_id) : (Price.t * string) list)
          ~bbo:(List.length bbo : int)
          ~l2:(List.length l2 : int)
          ~funding:(List.length funding : int)
          (gaps : Gap.t list)
          ~errors:(!errors : int)];
    [%expect
      {|
      ((trades ((100 0) (101 1))) (bbo 1) (l2 0) (funding 0)
       (gaps
        (((recv_ts "2026-01-01 00:00:03Z") (venue Binance)
          (instrument (((venue Binance) (symbol BTCUSDT)))) (stream (Trades))
          (reason Disconnect))))
       (errors 1))
      |}])
;;

let%expect_test "a feed without gaps closes its gaps pipe when the feed ends" =
  let feed = Replay_feed.of_events ~speed:0. (Pipe.of_list []) in
  let (module F) = Feed.With_gaps.of_feed feed in
  (* The replay ends by itself; nobody calls [close]. *)
  let%map gaps = Pipe.to_list F.gaps in
  print_s [%sexp (List.length gaps : int)];
  [%expect {| 0 |}]
;;
