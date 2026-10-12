open! Core
open! Async
open Market_data

let%expect_test "merges sorted pipes, ties by input order" =
  let input l = Pipe.of_list l in
  let merged =
    Merge.sorted
      ~compare:(fun (a, _) (b, _) -> Int.compare a b)
      [ input [ 1, "a"; 4, "a"; 9, "a" ]; input []; input [ 1, "c"; 2, "c"; 9, "c" ] ]
  in
  let%map l = Pipe.to_list merged in
  print_s [%sexp (l : (int * string) list)];
  [%expect {| ((1 a) (1 c) (2 c) (4 a) (9 a) (9 c)) |}]
;;

let%test_unit "quickcheck: merge equals stable sort of the concatenation" =
  Quickcheck.test
    ~sexp_of:[%sexp_of: int list list]
    (Quickcheck.Generator.list (Quickcheck.Generator.list Int.quickcheck_generator))
    ~f:(fun lists ->
      let lists = List.map lists ~f:(List.sort ~compare:Int.compare) in
      let merged =
        Thread_safe.block_on_async_exn (fun () ->
          Pipe.to_list
            (Merge.sorted ~compare:Int.compare (List.map lists ~f:Pipe.of_list)))
      in
      [%test_result: int list]
        merged
        ~expect:(List.sort (List.concat lists) ~compare:Int.compare))
;;

let eth = Instrument.create Hyperliquid "ETH"

(* Trade, bbo and funding of two instruments with equal [recv_ts] across files. *)
let replay_events : Event.t list =
  let eth_trade ~ms ~id =
    Event.Trade
      { (Sample.trade ~ms ~id ~price:"3500" ~size:"1" ()) with instrument = eth }
  in
  [ Trade (Sample.trade ~ms:0 ~id:"b0" ~price:"100" ~size:"1" ())
  ; Bbo (Sample.bbo ~ms:0 ~bid:"99" ~ask:"101")
  ; eth_trade ~ms:0 ~id:"e0"
  ; Trade (Sample.trade ~ms:5 ~id:"b5" ~price:"100" ~size:"1" ())
  ; eth_trade ~ms:3 ~id:"e3"
  ; Funding (Sample.funding ~ms:4 ~rate:0.0001)
  ; Bbo (Sample.bbo ~ms:5 ~bid:"99" ~ask:"101")
  ; eth_trade ~ms:9 ~id:"e9"
  ]
;;

let describe (e : Event.t) =
  let what =
    match e with
    | Trade t -> "trade " ^ t.trade_id
    | Bbo _ -> "bbo"
    | L2 _ -> "l2"
    | Funding _ -> "funding"
  in
  sprintf
    "%dms %s %s"
    (Time_ns.Span.to_int_ms (Time_ns.diff (Event.recv_ts e) (Sample.ts 0)))
    (Instrument.to_string (Event.instrument e))
    what
;;

let%expect_test "global replay order across instruments and streams" =
  Sample.with_temp_dir (fun dir ->
    let w = Event_log.Writer.create ~dir () in
    List.iter replay_events ~f:(Event_log.Writer.append w);
    let%bind () = Event_log.Writer.close w in
    let store = Store.create dir in
    let day = Date.of_string "2026-01-01" in
    let%bind instruments = Store.instruments store in
    let%bind files =
      Deferred.List.concat_map instruments ~how:`Sequential ~f:(fun i ->
        Store.files store Norm i [ Trades; Bbo; L2; Funding ] ~from:day ~to_:day)
    in
    List.iter files ~f:(fun f -> print_endline (Sample.relative ~dir f));
    let%map merged = Pipe.to_list (Event_log.read_merged files) in
    List.iter merged ~f:(fun e -> print_endline (describe e));
    [%expect
      {|
      hyperliquid/ETH/norm/trades/2026-01-01.bin
      binance/BTCUSDT/norm/trades/2026-01-01.bin
      binance/BTCUSDT/norm/bbo/2026-01-01.bin
      binance/BTCUSDT/norm/funding/2026-01-01.bin
      1ms hyperliquid:ETH trade e0
      1ms binance:BTCUSDT trade b0
      1ms binance:BTCUSDT bbo
      4ms hyperliquid:ETH trade e3
      5ms binance:BTCUSDT funding
      6ms binance:BTCUSDT trade b5
      6ms binance:BTCUSDT bbo
      10ms hyperliquid:ETH trade e9
      |}])
;;

let%test_unit "quickcheck: merged events are in recv_ts order, none lost or repeated" =
  let open Quickcheck.Generator.Let_syntax in
  (* Each input is one file: events of one stream with non-decreasing [recv_ts]. *)
  let file_gen index =
    let%map offsets = List.gen_non_empty (Int.gen_incl 0 50) in
    let ms = List.folding_map offsets ~init:0 ~f:(fun acc d -> acc + d, acc + d) in
    List.mapi ms ~f:(fun n ms ->
      Event.Trade (Sample.trade ~ms ~id:(sprintf "%d.%d" index n) ~price:"1" ~size:"1" ()))
  in
  let gen =
    let%bind n = Int.gen_incl 0 6 in
    List.init n ~f:file_gen |> Quickcheck.Generator.all
  in
  Quickcheck.test gen ~sexp_of:[%sexp_of: Event.t list list] ~f:(fun files ->
    let merged =
      Thread_safe.block_on_async_exn (fun () ->
        Pipe.to_list
          (Merge.sorted
             ~compare:Event.compare_by_recv_ts
             (List.map files ~f:Pipe.of_list)))
    in
    let ids l =
      List.map l ~f:(function
        | Event.Trade t -> t.trade_id
        | _ -> assert false)
    in
    assert (List.is_sorted merged ~compare:Event.compare_by_recv_ts);
    assert (not (List.contains_dup (ids merged) ~compare:String.compare));
    [%test_result: string list]
      (List.sort (ids merged) ~compare:String.compare)
      ~expect:(List.sort (ids (List.concat files)) ~compare:String.compare))
;;
