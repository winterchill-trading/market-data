open! Core
open! Async
open Market_data

let dir_flag =
  Command.Param.flag
    "-dir"
    (Command.Flag.required Command.Param.string)
    ~doc:"DIR market data root"
;;

(* Runs [day-close] for each instrument in its own process, at most [processes] at once,
   and prints their output in instrument order. *)
let day_close_processes ~processes ~dir ~date ~force ~jobs instruments =
  let%bind outputs =
    Deferred.List.map
      instruments
      ~how:(`Max_concurrent_jobs processes)
      ~f:(fun instrument ->
        Process.run
          ~prog:Sys_unix.executable_name
          ~args:
            ([ "day-close"
             ; "-dir"
             ; dir
             ; "-date"
             ; Date.to_string date
             ; "-venue"
             ; Venue.to_string (Instrument.venue instrument)
             ; "-symbol"
             ; Symbol.to_string (Instrument.symbol instrument)
             ; "-jobs"
             ; Int.to_string jobs
             ]
             @ if force then [ "-force" ] else [])
          ())
  in
  List.iter outputs ~f:(fun output -> print_string (Or_error.ok_exn output));
  return ()
;;

let day_close =
  Command.async
    ~summary:"Convert a closed day of norm/ event logs into parquet/ tables"
    (let%map_open.Command dir = dir_flag
     and date =
       flag
         "-date"
         (optional date)
         ~doc:"YYYY-MM-DD UTC day to convert (default: yesterday)"
     and venue = flag "-venue" (optional string) ~doc:"VENUE only this venue"
     and symbol =
       flag "-symbol" (optional string) ~doc:"SYMBOL only this symbol (needs -venue)"
     and force = flag "-force" no_arg ~doc:" rewrite tables that are up to date"
     and jobs =
       flag
         "-jobs"
         (optional_with_default 1 int)
         ~doc:"N tables to convert at once (default 1)"
     and processes =
       flag
         "-processes"
         (optional_with_default 1 int)
         ~doc:"N instruments to convert at once, each in its own process (default 1)"
     in
     fun () ->
       let today = Store.date_of_time (Time_ns.now ()) in
       let date = Option.value date ~default:(Date.add_days today (-1)) in
       if Date.( >= ) date today
       then
         Log.Global.info_s
           [%message "converting a day that may still be written" (date : Date.t)];
       let%bind instruments =
         match venue, symbol with
         | None, None -> return None
         | None, Some _ -> raise_s [%message "-symbol needs -venue"]
         | Some venue, Some symbol ->
           return (Some [ Instrument.create (Venue.of_string venue) symbol ])
         | Some venue, None ->
           let venue = Venue.of_string venue in
           let%map all = Store.instruments (Store.create dir) in
           Some (List.filter all ~f:(fun i -> Venue.equal (Instrument.venue i) venue))
       in
       if processes > 1
       then (
         let%bind instruments =
           match instruments with
           | Some l -> return l
           | None -> Store.instruments (Store.create dir)
         in
         day_close_processes ~processes ~dir ~date ~force ~jobs instruments)
       else (
         let%map results = Day_close.run ~force ~jobs ?instruments ~dir date in
         List.iter results ~f:(fun (r : Day_close.Result.t) ->
           match r.outcome with
           | No_source -> ()
           | Up_to_date -> printf "up to date %s\n" r.path
           | Written { rows; tail } ->
             printf "wrote %s (%d rows)\n" r.path rows;
             Option.iter r.stats ~f:(fun (s : Day_close.Stats.t) ->
               printf
                 !"  %s: %d frames (%d bytes) in, %d bytes out, %{Time_ns.Span}%s\n"
                 (Parquet_kind.to_string r.kind)
                 s.input_frames
                 s.input_bytes
                 s.output_bytes
                 s.elapsed
                 (match s.replaced_parts with
                  | [] -> ""
                  | parts -> ", replaced " ^ String.concat ~sep:" " parts));
             (match tail with
              | Clean -> ()
              | tail -> print_s [%message "  damaged source" (tail : Framed.Tail.t)]))))
;;

let views =
  Command.async
    ~summary:"Print DuckDB CREATE VIEW statements for every parquet table"
    (let%map_open.Command dir = dir_flag in
     fun () ->
       let%map units_csv = Parquet_views.units_csv ~dir in
       print_endline (Parquet_views.sql ~dir ());
       print_endline (Parquet_views.derived_sql ?units_csv Parquet_kind.all))
;;

let time_arg = Command.Arg_type.create Time_ns.of_string_with_utc_offset

let dump =
  Command.async
    ~summary:"Print the events of norm/ event log files, merged by recv_ts"
    ~readme:(fun () ->
      "With -book-at, print instead the L2 book of each instrument after every update \
       received at or before TIME.")
    (let%map_open.Command book_at =
       flag
         "-book-at"
         (optional time_arg)
         ~doc:"TIME rebuild L2 books as of this time, e.g. 2026-01-01T00:00:00.5Z"
     and depth = flag "-depth" (optional int) ~doc:"N levels per side (default all)"
     and files = anon (non_empty_sequence_as_list ("FILE" %: Filename_unix.arg_type)) in
     fun () ->
       match book_at with
       | None -> Event_dump.print files
       | Some at ->
         let%map books = Event_dump.book_at files ~at in
         if List.is_empty books then print_endline "no L2 updates before that time";
         List.iter books ~f:(fun (instrument, book) ->
           printf
             "%s%s at %s\n%s"
             (Instrument.to_string instrument)
             (if L2_book.has_snapshot book then "" else " (no snapshot yet)")
             (Option.value_map
                (L2_book.last_update book)
                ~default:"-"
                ~f:(Time_ns.to_string_iso8601_basic ~zone:Time_float.Zone.utc))
             (L2_book.to_string_hum ?depth book)))
;;

let default_duckdb =
  match Core_unix.access "/opt/homebrew/bin/duckdb" [ `Exec ] with
  | Ok () -> "/opt/homebrew/bin/duckdb"
  | Error _ -> "duckdb"
;;

let format_arg =
  Command.Arg_type.of_alist_exn
    (List.map Parquet_views.Format.all ~f:(fun f -> Parquet_views.Format.to_string f, f))
;;

let query =
  Command.async_or_error
    ~summary:"Run SQL with DuckDB over the parquet views (trades, bbo, l2, ...)"
    (let%map_open.Command dir = dir_flag
     and duckdb =
       flag
         "-duckdb"
         (optional_with_default default_duckdb string)
         ~doc:(sprintf "PATH duckdb binary (default %s)" default_duckdb)
     and format =
       flag
         "-format"
         (optional_with_default Parquet_views.Format.Box format_arg)
         ~doc:"FORMAT box, csv, json or markdown (default box)"
     and no_log =
       flag "-no-log" no_arg ~doc:" do not append the query to DIR/query-log.ndjson"
     and sql = anon ("SQL" %: string) in
     fun () ->
       let%bind () = if no_log then return () else Query_log.append ~dir sql in
       let%map.Deferred.Or_error output = Parquet_views.query ~duckdb ~format ~dir sql in
       print_string output)
;;

let check =
  Command.async_or_error
    ~summary:"Data-quality assertions over the parquet tables (exits 1 on violations)"
    ~readme:(fun () ->
      "Counts recv_ts gaps longer than -max-gap per instrument (trades, bbo, l2), \
       non-positive sizes and crossed bbo, then prints the largest gaps.")
    (let%map_open.Command dir = dir_flag
     and duckdb =
       flag
         "-duckdb"
         (optional_with_default default_duckdb string)
         ~doc:(sprintf "PATH duckdb binary (default %s)" default_duckdb)
     and max_gap =
       flag
         "-max-gap"
         (optional_with_default Time_ns.Span.minute Time_ns.Span.arg_type)
         ~doc:"SPAN longest allowed recv_ts gap (default 1m)"
     and show_gaps =
       flag
         "-show-gaps"
         (optional_with_default 20 int)
         ~doc:"N gaps to print (default 20)"
     in
     fun () ->
       let%bind.Deferred.Or_error report =
         Quality_check.run ~duckdb ~max_gap ~show_gaps ~dir ()
       in
       List.iter report.checks ~f:(fun (c : Quality_check.Check.t) ->
         printf
           "%-4s %-18s %-7s %d\n"
           (if c.violations > 0 then "FAIL" else "ok")
           c.name
           (Parquet_kind.to_string c.table)
           c.violations);
       if not (String.is_empty (String.strip report.gaps))
       then printf "\nlargest gaps:\n%s" report.gaps;
       match Quality_check.Report.failed report with
       | [] -> Deferred.Or_error.ok_unit
       | failed ->
         Deferred.Or_error.error_s
           [%message "quality checks failed" ~checks:(List.length failed : int)])
;;

let catalog =
  Command.async
    ~summary:"Per table: venues, symbol count, first and last day, files, leftover parts"
    (let%map_open.Command dir = dir_flag in
     fun () ->
       let%map entries = Catalog.scan ~dir in
       print_string (Catalog.to_string_hum entries))
;;

let () =
  Command.group
    ~summary:"Recorded market data tools"
    [ "day-close", day_close
    ; "views", views
    ; "query", query
    ; "dump", dump
    ; "check", check
    ; "catalog", catalog
    ; "rebuild-norm", Rebuild_norm.command []
    ]
  |> Command_unix.run
;;
