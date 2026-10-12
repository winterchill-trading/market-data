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
  let script = sql ~kinds ~dir () ^ "\n" ^ query in
  Process.run
    ~prog:duckdb
    ~args:[ ":memory:"; "-" ^ Format.to_string format ]
    ~stdin:script
    ()
;;
