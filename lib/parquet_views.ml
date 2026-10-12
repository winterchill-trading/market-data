open! Core
open! Async

let glob ~dir kind = dir ^/ "*/*/parquet" ^/ Parquet_kind.to_string kind ^/ "*.parquet"
let quote s = "'" ^ String.substr_replace_all s ~pattern:"'" ~with_:"''" ^ "'"

let create_view ~dir kind =
  sprintf
    "CREATE VIEW %s AS SELECT * FROM read_parquet(%s, hive_partitioning=false);"
    (Parquet_kind.to_string kind)
    (quote (glob ~dir kind))
;;

let sql ?(kinds = Parquet_kind.all) ~dir () =
  List.map kinds ~f:(create_view ~dir) |> String.concat ~sep:"\n"
;;

let lag_kinds = [ Parquet_kind.Trades; Bbo; L2; Funding ]

let derived_sql ?units_csv kinds =
  let has k = List.mem kinds k ~equal:Parquet_kind.equal in
  let trades_with_bbo =
    if has Trades && has Bbo
    then
      [ "CREATE VIEW trades_with_bbo AS SELECT t.*, b.recv_ts AS bbo_recv_ts,          \
         b.bid_price, b.bid_size, b.ask_price, b.ask_size FROM trades t ASOF LEFT \
         JOIN          bbo b ON t.venue = b.venue AND t.symbol = b.symbol AND t.recv_ts \
         >= b.recv_ts;"
      ]
    else []
  in
  let lag =
    match List.filter lag_kinds ~f:has with
    | [] -> []
    | present ->
      let one kind =
        sprintf
          "SELECT '%s' AS table_name, venue, symbol, (epoch_ns(recv_ts) -            \
           epoch_ns(exch_ts)) / 1e6 AS lag_ms FROM %s"
          (Parquet_kind.to_string kind)
          (Parquet_kind.to_string kind)
      in
      [ sprintf
          "CREATE VIEW lag AS SELECT table_name, venue, symbol, count(*) AS \
           n,            quantile_cont(lag_ms, 0.5) AS p50_ms, quantile_cont(lag_ms, \
           0.99) AS p99_ms            FROM (%s) GROUP BY ALL;"
          (String.concat ~sep:" UNION ALL " (List.map present ~f:one))
      ]
  in
  let units = [ Contract_units.create_table_sql ?csv:units_csv () ] in
  let token_bbo =
    if has Bbo
    then
      [ "CREATE VIEW token_bbo AS SELECT b.venue, b.symbol, u.token, b.exch_ts,          \
         b.recv_ts, b.bid_price::DOUBLE / u.units_per_price AS bid,          \
         b.ask_price::DOUBLE / u.units_per_price AS ask, (b.bid_price::DOUBLE +          \
         b.ask_price::DOUBLE) / 2 / u.units_per_price AS mid, b.bid_size::DOUBLE \
         *          u.units_per_contract AS bid_qty, b.ask_size::DOUBLE * \
         u.units_per_contract AS          ask_qty FROM bbo b JOIN units_per_contract u \
         USING (venue, symbol);"
      ]
    else []
  in
  String.concat ~sep:"\n" (trades_with_bbo @ lag @ units @ token_bbo)
;;

let units_csv ~dir =
  let path = dir ^/ "units_per_contract.csv" in
  match%map Sys.file_exists_exn path with
  | true -> Some path
  | false -> None
;;

let has_parquet dir =
  match%bind Sys.is_directory_exn dir with
  | false -> return false
  | true ->
    let%map names = Sys.readdir dir in
    Array.exists names ~f:(String.is_suffix ~suffix:".parquet")
;;

let existing_kinds ~dir =
  let%bind instruments = Store.instruments (Store.create dir) in
  Deferred.List.filter Parquet_kind.all ~how:`Sequential ~f:(fun kind ->
    Deferred.List.exists instruments ~f:(fun instrument ->
      has_parquet (Parquet_kind.kind_dir ~dir instrument kind)))
;;

module Format = struct
  type t =
    | Box
    | Csv
    | Json
    | Markdown
  [@@deriving sexp, compare, equal, enumerate]

  let to_string = function
    | Box -> "box"
    | Csv -> "csv"
    | Json -> "json"
    | Markdown -> "markdown"
  ;;
end

let query ?(duckdb = "duckdb") ?(format = Format.Box) ~dir query =
  let%bind kinds = existing_kinds ~dir in
  let%bind units_csv = units_csv ~dir in
  let script =
    String.concat ~sep:"\n" [ sql ~kinds ~dir (); derived_sql ?units_csv kinds; query ]
  in
  Process.run
    ~prog:duckdb
    ~args:[ ":memory:"; "-" ^ Format.to_string format ]
    ~stdin:script
    ()
;;
