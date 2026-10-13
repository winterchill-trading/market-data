open! Core
open! Async
open Market_data

let before_midnight = Time_ns.of_string_with_utc_offset "2026-01-01 23:59:59Z"
let after_midnight = Time_ns.of_string_with_utc_offset "2026-01-02 00:00:01Z"

let sink ?max_pending_rows ~time_source ~dir ~row_group_rows () =
  Parquet_sink.create
    ~time_source:(Time_source.read_only time_source)
    ?max_pending_rows
    Parquet_schemas.trade
    ~dir
    Sample.btc
    Trades
    ~row_group_rows
;;

let trade ms = Sample.trade ~ms ~price:"100" ~size:"1" ()

let print_files ~dir sink =
  List.iter (Parquet_sink.files sink) ~f:(fun f -> print_endline (Sample.relative ~dir f))
;;

let rec wait_for_file ?(tries = 500) path =
  match%bind Sys.file_exists_exn path with
  | true -> return true
  | false when tries = 0 -> return false
  | false ->
    let%bind () = Clock_ns.after (Time_ns.Span.of_int_ms 10) in
    wait_for_file ~tries:(tries - 1) path
;;

let query ~dir sql =
  match%map Parquet_views.query ~format:Csv ~dir sql with
  | Ok out -> print_string out
  | Error e -> print_s [%sexp (e : Error.t)]
;;

let%expect_test "the sink rotates at UTC midnight of its clock" =
  Sample.with_temp_dir (fun dir ->
    let time_source = Time_source.create ~now:before_midnight () in
    let s = sink ~time_source ~dir ~row_group_rows:2 () in
    List.iter [ 1; 2; 3 ] ~f:(fun ms -> Parquet_sink.add s (trade ms));
    printf "pending after 3 rows: %d\n" (Parquet_sink.pending s);
    Time_source.advance_directly time_source ~to_:after_midnight;
    Parquet_sink.add s (trade 4);
    (* The first row of the new day closes yesterday's file without waiting for [close]. *)
    let%bind closed =
      wait_for_file
        (Parquet_kind.path ~dir Sample.btc Trades (Date.of_string "2026-01-01"))
    in
    printf "day one closed before close: %b\n" closed;
    let%bind () = Parquet_sink.close s in
    print_files ~dir s;
    [%expect
      {|
      pending after 3 rows: 2
      day one closed before close: true
      binance/BTCUSDT/parquet/trades/2026-01-01.parquet
      binance/BTCUSDT/parquet/trades/2026-01-02.parquet
      |}];
    let glob = Parquet_views.glob ~dir Trades in
    let%bind () =
      query
        ~dir
        (sprintf
           "SELECT parse_filename(file_name) AS file, count(DISTINCT row_group_id) AS \
            row_groups, max(row_group_num_rows) AS max_rows FROM parquet_metadata('%s') \
            GROUP BY ALL ORDER BY ALL"
           glob)
    in
    [%expect
      {|
      file,row_groups,max_rows
      2026-01-01.parquet,2,2
      2026-01-02.parquet,1,1
      |}];
    let%bind () = query ~dir "SELECT trade_id FROM trades ORDER BY ALL" in
    [%expect {|
      trade_id
      1
      2
      3
      4
      |}];
    (* A restart on the same day must not overwrite the closed file. *)
    let s = sink ~time_source ~dir ~row_group_rows:2 () in
    Parquet_sink.add s (trade 5);
    let%bind () = Parquet_sink.close s in
    print_files ~dir s;
    let%bind () = query ~dir "SELECT count(*) AS n FROM trades" in
    [%expect
      {|
      binance/BTCUSDT/parquet/trades/2026-01-02.1.parquet
      n
      5
      |}];
    return ())
;;

let%expect_test "batches beyond max_pending_rows are dropped, not blocking" =
  Sample.with_temp_dir (fun dir ->
    let time_source = Time_source.create ~now:before_midnight () in
    let s = sink ~max_pending_rows:2 ~time_source ~dir ~row_group_rows:1 () in
    List.iter (List.range 0 5) ~f:(fun ms -> Parquet_sink.add s (trade ms));
    printf "pending %d, dropped %d\n" (Parquet_sink.pending s) (Parquet_sink.dropped s);
    let%bind () = Parquet_sink.close s in
    let%bind () = query ~dir "SELECT trade_id FROM trades ORDER BY ALL" in
    [%expect {|
      pending 2, dropped 3
      trade_id
      0
      1
      |}];
    return ())
;;

let%expect_test "add after close raises" =
  Sample.with_temp_dir (fun dir ->
    let time_source = Time_source.create ~now:before_midnight () in
    let s = sink ~time_source ~dir ~row_group_rows:1 () in
    let%bind () = Parquet_sink.close s in
    let%bind () = Parquet_sink.close s in
    print_s
      [%sexp
        (Or_error.try_with (fun () -> Parquet_sink.add s (trade 0)) : unit Or_error.t)];
    printf "files: %d\n" (List.length (Parquet_sink.files s));
    [%expect {|
      (Error "Parquet_sink.add: closed")
      files: 0
      |}];
    return ())
;;

let%expect_test "a direct sink writes the same file and adds rows without the schema" =
  let run ~direct =
    Sample.with_temp_dir (fun dir ->
      let time_source = Time_source.create ~now:before_midnight () in
      let s =
        Parquet_sink.create
          ~time_source:(Time_source.read_only time_source)
          ?direct
          Parquet_schemas.trade
          ~dir
          Sample.btc
          Trades
          ~row_group_rows:64
      in
      let rows =
        Array.init 1_000 ~f:(fun ms -> Sample.trade ~ms ~price:"100.5" ~size:"0.25" ())
      in
      Array.iter (Array.sub rows ~pos:0 ~len:500) ~f:(Parquet_sink.add s);
      (* After the warm-up: what [add] itself costs per row on the caller's side. *)
      let before = Gc.minor_words () in
      Array.iter (Array.sub rows ~pos:500 ~len:500) ~f:(Parquet_sink.add s);
      let words = Float.of_int (Gc.minor_words () - before) /. 500. in
      let%map () = Parquet_sink.close s in
      words, In_channel.read_all (List.hd_exn (Parquet_sink.files s)))
  in
  let%bind schema_words, schema_file = run ~direct:None in
  let%map direct_words, direct_file = run ~direct:(Some Parquet_schemas.Direct.trade) in
  printf
    "same file: %b\nadd: %.1f words/row (schema sink %.1f)\n"
    (String.equal schema_file direct_file)
    direct_words
    schema_words;
  [%expect {|
    same file: true
    add: 3.1 words/row (schema sink 3.1)
    |}]
;;
