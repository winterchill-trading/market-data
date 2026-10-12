open! Core
open! Async

module Check = struct
  type t =
    { name : string
    ; table : Parquet_kind.t
    ; violations : int
    }
  [@@deriving sexp_of, compare, equal]
end

let gap_kinds kinds =
  List.filter kinds ~f:(fun (k : Parquet_kind.t) ->
    match k with
    | Trades | Bbo | L2 -> true
    | Funding | Candles -> false)
;;

let gaps_view ~max_gap kinds =
  let max_gap_ns = Int63.to_string (Time_ns.Span.to_int63_ns max_gap) in
  let one kind =
    let table = Parquet_kind.to_string kind in
    sprintf
      "SELECT '%s' AS table_name, venue, symbol, prev AS from_ts, recv_ts AS to_ts, \
       (epoch_ns(recv_ts) - epoch_ns(prev)) / 1e6 AS gap_ms FROM (SELECT venue, symbol, \
       recv_ts, lag(recv_ts) OVER (PARTITION BY venue, symbol ORDER BY recv_ts) AS prev \
       FROM %s) WHERE epoch_ns(recv_ts) - epoch_ns(prev) > %s"
      table
      table
      max_gap_ns
  in
  match gap_kinds kinds with
  | [] ->
    "CREATE VIEW gaps AS SELECT NULL::VARCHAR AS table_name, NULL::VARCHAR AS venue, \
     NULL::VARCHAR AS symbol, NULL::TIMESTAMP_NS AS from_ts, NULL::TIMESTAMP_NS AS \
     to_ts, NULL::DOUBLE AS gap_ms WHERE false;"
  | kinds ->
    "CREATE VIEW gaps AS "
    ^ String.concat ~sep:" UNION ALL " (List.map kinds ~f:one)
    ^ ";"
;;

let checks kind : (string * string) list =
  let gap =
    [ ( "recv_ts_gap"
      , sprintf
          "(SELECT count(*) FROM gaps WHERE table_name = '%s')"
          (Parquet_kind.to_string kind) )
    ]
  in
  let count where =
    sprintf "(SELECT count(*) FROM %s WHERE %s)" (Parquet_kind.to_string kind) where
  in
  match (kind : Parquet_kind.t) with
  | Trades -> gap @ [ "non_positive_size", count "size <= 0" ]
  | Bbo ->
    gap
    @ [ "non_positive_size", count "bid_size <= 0 OR ask_size <= 0"
      ; "crossed_bbo", count "bid_price > ask_price"
      ]
  | L2 -> gap @ [ "non_positive_size", count "size < 0 OR (is_snapshot AND size = 0)" ]
  | Funding | Candles -> []
;;

let summary_sql kinds =
  let rows =
    List.concat_map kinds ~f:(fun kind ->
      List.map (checks kind) ~f:(fun (name, expr) ->
        sprintf
          "SELECT '%s' AS check_name, '%s' AS table_name, %s AS violations"
          name
          (Parquet_kind.to_string kind)
          expr))
  in
  match rows with
  | [] -> "SELECT NULL AS check_name, NULL AS table_name, NULL AS violations WHERE false;"
  | rows -> String.concat ~sep:" UNION ALL " rows ^ ";"
;;

module Report = struct
  type t =
    { checks : Check.t list
    ; gaps : string
    }

  let failed t = List.filter t.checks ~f:(fun c -> c.violations > 0)
end

let parse_summary csv =
  String.split_lines csv
  |> List.tl
  |> Option.value ~default:[]
  |> List.map ~f:(fun line ->
    match String.split line ~on:',' with
    | [ name; table; violations ] ->
      { Check.name
      ; table = Parquet_kind.of_string table
      ; violations = Int.of_string violations
      }
    | _ -> raise_s [%message "Quality_check: unexpected summary row" line])
  |> List.sort ~compare:Check.compare
;;

let run ?duckdb ?(max_gap = Time_ns.Span.minute) ?(show_gaps = 20) ~dir () =
  let open Deferred.Or_error.Let_syntax in
  let%bind kinds = Deferred.ok (Parquet_views.existing_kinds ~dir) in
  let view = gaps_view ~max_gap kinds in
  let%bind summary =
    Parquet_views.query ?duckdb ~format:Csv ~dir (view ^ "\n" ^ summary_sql kinds)
  in
  let%bind checks =
    Deferred.return (Or_error.try_with (fun () -> parse_summary summary))
  in
  let%map gaps =
    Parquet_views.query
      ?duckdb
      ~format:Csv
      ~dir
      (sprintf
         "%s\n\
          SELECT * FROM gaps ORDER BY gap_ms DESC, table_name, venue, symbol, to_ts \
          LIMIT %d;"
         view
         show_gaps)
  in
  { Report.checks; gaps }
;;
