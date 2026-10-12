open! Core
open! Async
open Market_data

let dir_flag =
  Command.Param.flag
    "-dir"
    (Command.Flag.required Command.Param.string)
    ~doc:"DIR market data root"
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
     and force = flag "-force" no_arg ~doc:" rewrite tables that are up to date" in
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
       let%map results = Day_close.run ~force ?instruments ~dir date in
       List.iter results ~f:(fun (r : Day_close.Result.t) ->
         match r.outcome with
         | No_source -> ()
         | Up_to_date -> printf "up to date %s\n" r.path
         | Written { rows; tail } ->
           printf "wrote %s (%d rows)\n" r.path rows;
           (match tail with
            | Clean -> ()
            | tail -> print_s [%message "  damaged source" (tail : Framed.Tail.t)])))
;;

let views =
  Command.async
    ~summary:"Print DuckDB CREATE VIEW statements for every parquet table"
    (let%map_open.Command dir = dir_flag in
     fun () ->
       print_endline (Parquet_views.sql ~dir ());
       return ())
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
     and sql = anon ("SQL" %: string) in
     fun () ->
       let%map.Deferred.Or_error output = Parquet_views.query ~duckdb ~format ~dir sql in
       print_string output)
;;

let () =
  Command.group
    ~summary:"Recorded market data tools"
    [ "day-close", day_close; "views", views; "query", query ]
  |> Command_unix.run
;;
