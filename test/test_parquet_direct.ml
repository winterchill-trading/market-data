open! Core
open! Async
open Market_data

let eth = Instrument.create Hyperliquid "ETH"

let units k =
  Price.of_string (sprintf "%d.%08d" (100 + (k % 50_000)) (k * 7919 % 100_000_000))
;;

let qty k = Size.of_string (sprintf "%d.%04d" (k % 13) (k * 31 % 10_000))
let instrument k = if k % 3 = 0 then eth else Sample.btc

let trade k : Trade.t =
  { instrument = instrument k
  ; exch_ts = Sample.ts k
  ; recv_ts = Sample.ts (k + 1)
  ; price = units k
  ; size = qty k
  ; side = (if k % 2 = 0 then Buy else Sell)
  ; trade_id = sprintf "t-%d" k
  }
;;

let bbo k : Bbo.t =
  { instrument = instrument k
  ; exch_ts = Sample.ts k
  ; recv_ts = Sample.ts (k + 2)
  ; bid_price = units k
  ; bid_size = qty k
  ; ask_price = units (k + 1)
  ; ask_size = qty (k + 5)
  }
;;

let l2_update k : L2_update.t =
  let levels n =
    List.init n ~f:(fun i ->
      { L2_update.Level.price = units (k + i); size = qty (k * i) })
  in
  { instrument = instrument k
  ; exch_ts = Sample.ts k
  ; recv_ts = Sample.ts (k + 3)
  ; kind = (if k % 10 = 0 then Snapshot else Delta)
  ; bids = levels (k % 4)
  ; asks = levels (k % 3)
  }
;;

let funding k : Funding.t =
  { instrument = instrument k
  ; exch_ts = Sample.ts k
  ; recv_ts = Sample.ts (k + 1)
  ; rate = Float.of_int ((k % 17) - 8) *. 1.25e-5
  ; next_funding_time = Sample.ts (k + 3_600_000)
  ; mark_price = units k
  ; index_price = units (k + 2)
  }
;;

let candle k : Candle.t =
  { instrument = instrument k
  ; interval = Time_ns.Span.minute
  ; open_time = Sample.ts (k * 60_000)
  ; open_ = units k
  ; high = units (k + 9)
  ; low = units (k + 1)
  ; close = units (k + 4)
  ; volume = qty k
  ; trade_count = k * 3
  }
;;

let write ~schema ~compression ~row_group_rows path f =
  Parquet.Writer.with_file ~schema ~compression ~row_group_rows path ~f
;;

(* Writes [rows] once through the schema accessors and once through [direct], and compares
   the files byte for byte. *)
let same_bytes ~dir ~name ~schema ~direct rows =
  List.iter [ `None; `Zstd ] ~f:(fun compression ->
    List.iter [ 7; 1_000 ] ~f:(fun row_group_rows ->
      let old_path = dir ^/ name ^ ".schema.parquet"
      and new_path = dir ^/ name ^ ".direct.parquet" in
      write ~schema ~compression ~row_group_rows old_path (fun w ->
        Parquet.Writer.add_all w rows);
      write ~schema ~compression ~row_group_rows new_path (fun w -> direct w);
      let old_bytes = In_channel.read_all old_path
      and new_bytes = In_channel.read_all new_path in
      if not (String.equal old_bytes new_bytes)
      then
        raise_s
          [%message
            "Direct file differs"
              name
              (row_group_rows : int)
              (String.length old_bytes : int)
              (String.length new_bytes : int)]));
  printf "%s: identical\n" name
;;

let%expect_test "direct writers write the same files as the schemas" =
  Sample.with_temp_dir (fun dir ->
    let n = 500 in
    let each f = List.init n ~f in
    let via direct rows w =
      let add = direct w in
      List.iter rows ~f:add
    in
    let trades = each trade
    and bbos = each bbo
    and fundings = each funding
    and candles = each candle
    and updates = each l2_update in
    same_bytes
      ~dir
      ~name:"trade"
      ~schema:Parquet_schemas.trade
      ~direct:(via Parquet_schemas.Direct.trade trades)
      trades;
    same_bytes
      ~dir
      ~name:"bbo"
      ~schema:Parquet_schemas.bbo
      ~direct:(via Parquet_schemas.Direct.bbo bbos)
      bbos;
    same_bytes
      ~dir
      ~name:"funding"
      ~schema:Parquet_schemas.funding
      ~direct:(via Parquet_schemas.Direct.funding fundings)
      fundings;
    same_bytes
      ~dir
      ~name:"candle"
      ~schema:Parquet_schemas.candle
      ~direct:(via Parquet_schemas.Direct.candle candles)
      candles;
    let l2_rows =
      List.concat_mapi updates ~f:(fun seq u -> Parquet_schemas.L2_row.of_update ~seq u)
    in
    same_bytes
      ~dir
      ~name:"l2"
      ~schema:Parquet_schemas.l2
      ~direct:(via Parquet_schemas.Direct.l2 l2_rows)
      l2_rows;
    same_bytes
      ~dir
      ~name:"l2_update"
      ~schema:Parquet_schemas.l2
      ~direct:(fun w ->
        let add = Parquet_schemas.Direct.l2_update w in
        List.iteri updates ~f:(fun seq u -> add ~seq u))
      l2_rows;
    [%expect
      {|
      trade: identical
      bbo: identical
      funding: identical
      candle: identical
      l2: identical
      l2_update: identical
      |}];
    return ())
;;

(* Minor words for [rows] calls of [add] after a warm-up of three row groups, staying
   clear of a row group boundary: flushing a group allocates its page metadata. *)
let words_per_row ?(rows_per_call = 1) ~dir ~schema ~direct ~row () =
  let calls = 1_024 in
  let row_group_rows = calls * rows_per_call in
  write ~schema ~compression:`None ~row_group_rows (dir ^/ "words.parquet") (fun w ->
    let add = direct w in
    let rows = Array.init calls ~f:row in
    for k = 0 to (3 * calls) - 1 do
      add rows.(k % calls)
    done;
    let before = Gc.minor_words () in
    for k = 0 to calls - 2 do
      add rows.(k)
    done;
    Float.of_int (Gc.minor_words () - before) /. Float.of_int (calls - 1))
;;

let%expect_test "direct writers allocate nothing per row once warm" =
  Sample.with_temp_dir (fun dir ->
    let show name words = printf "%-9s %.2f words/row\n" name words in
    show
      "trade"
      (words_per_row
         ~dir
         ~schema:Parquet_schemas.trade
         ~direct:Parquet_schemas.Direct.trade
         ~row:trade
         ());
    show
      "bbo"
      (words_per_row
         ~dir
         ~schema:Parquet_schemas.bbo
         ~direct:Parquet_schemas.Direct.bbo
         ~row:bbo
         ());
    show
      "funding"
      (words_per_row
         ~dir
         ~schema:Parquet_schemas.funding
         ~direct:Parquet_schemas.Direct.funding
         ~row:funding
         ());
    show
      "candle"
      (words_per_row
         ~dir
         ~schema:Parquet_schemas.candle
         ~direct:Parquet_schemas.Direct.candle
         ~row:candle
         ());
    let l2_row k =
      List.hd_exn
        (Parquet_schemas.L2_row.of_update
           ~seq:k
           { (l2_update 1) with bids = (l2_update 5).bids })
    in
    show
      "l2"
      (words_per_row
         ~dir
         ~schema:Parquet_schemas.l2
         ~direct:Parquet_schemas.Direct.l2
         ~row:l2_row
         ());
    (* Five levels (five rows) per update: words are per update here. *)
    show
      "l2_update"
      (words_per_row
         ~rows_per_call:5
         ~dir
         ~schema:Parquet_schemas.l2
         ~direct:(fun w ->
           let add = Parquet_schemas.Direct.l2_update w in
           fun u -> add ~seq:0 u)
         ~row:(fun k ->
           { (l2_update k) with bids = (l2_update 3).bids; asks = (l2_update 2).asks })
         ());
    [%expect
      {|
      trade     0.00 words/row
      bbo       0.00 words/row
      funding   0.00 words/row
      candle    0.00 words/row
      l2        0.00 words/row
      l2_update 0.00 words/row
      |}];
    return ())
;;
