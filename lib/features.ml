open! Core
open! Async

module Bucket = struct
  type t =
    | Fixed of Size.t
    | Per_day of int
  [@@deriving sexp, compare, equal]
end

module Toxicity_spec = struct
  type t =
    { bucket : Bucket.t
    ; window : int
    ; zscore_window : int
    ; classification : Toxicity.Classification.t
    }
  [@@deriving sexp, compare, equal]

  let default =
    { bucket = Per_day 50; window = 50; zscore_window = 250; classification = Aggressor }
  ;;
end

module Result = struct
  type t =
    { instrument : Instrument.t
    ; trades : int
    ; bars : (string * int) option
    ; toxicity : (string * int * Size.t) option
    }
  [@@deriving sexp_of]
end

(* Beside the day-close tables: the parent of [parquet/trades]. *)
let table_path ~dir instrument name date =
  Filename.dirname (Parquet_kind.kind_dir ~dir instrument Trades)
  ^/ name
  ^/ Date.to_string date
  ^ ".parquet"
;;

let bars_path ~dir instrument date = table_path ~dir instrument "bars" date
let toxicity_path ~dir instrument date = table_path ~dir instrument "toxicity" date

(* Feeds every trade of [source] to [f]; returns the trade count. *)
let iter_trades source ~f =
  let events, (_ : Framed.Tail.t Deferred.t) = Event_log.read_file source in
  Pipe.fold_without_pushback events ~init:0 ~f:(fun n -> function
    | Event.Trade trade ->
      f trade;
      n + 1
    | Bbo _ | L2 _ | Funding _ -> n)
;;

let bucket_volume source (spec : Toxicity_spec.t) =
  match spec.bucket with
  | Fixed size -> return size
  | Per_day n ->
    let total = ref 0 in
    let%map (_ : int) =
      iter_trades source ~f:(fun t -> total := !total + Size.to_units t.size)
    in
    Size.of_units (Int.max 1 (!total / Int.max 1 n))
;;

let write schema path rows =
  let%bind file =
    Parquet_file.create ~compression:`Zstd schema ~row_group_rows:65_536 path
  in
  let%bind () = Parquet_file.add file rows in
  let%map () = Parquet_file.close file in
  path, List.length rows
;;

let instrument_day ?toxicity ~dir ~bars instrument date =
  let source = Event_log.path ~dir instrument Trades date in
  match%bind Sys.file_exists_exn source with
  | false -> return None
  | true ->
    let%bind bucket =
      match toxicity with
      | None -> return None
      | Some spec -> bucket_volume source spec >>| Option.some
    in
    let folds = List.map bars ~f:(fun spec -> Bars.create instrument spec) in
    let tox =
      Option.map2 toxicity bucket ~f:(fun (spec : Toxicity_spec.t) bucket_volume ->
        Toxicity.create
          instrument
          { bucket_volume
          ; window = spec.window
          ; zscore_window = spec.zscore_window
          ; classification = spec.classification
          })
    in
    let bar_rows = ref [] in
    let tox_rows = ref [] in
    let%bind trades =
      iter_trades source ~f:(fun trade ->
        List.iter folds ~f:(fun b ->
          match Bars.add b trade with
          | This bar ->
            bar_rows
            := { Feature_schemas.Bar_row.bar_type = Bars.Spec.to_string (Bars.spec b)
               ; complete = true
               ; bar
               }
               :: !bar_rows
          | Null -> ());
        Option.iter tox ~f:(fun t ->
          List.iter (Toxicity.add t trade) ~f:(fun e -> tox_rows := e :: !tox_rows)))
    in
    List.iter folds ~f:(fun b ->
      Option.iter (Bars.current b) ~f:(fun bar ->
        bar_rows
        := { Feature_schemas.Bar_row.bar_type = Bars.Spec.to_string (Bars.spec b)
           ; complete = false
           ; bar
           }
           :: !bar_rows));
    Option.iter tox ~f:(fun t ->
      List.iter (Toxicity.flush t) ~f:(fun e -> tox_rows := e :: !tox_rows));
    let%bind bars =
      if List.is_empty bars
      then return None
      else (
        (* One bar type after the other, each in time order. *)
        let rows =
          List.rev !bar_rows
          |> List.stable_sort ~compare:(fun (a : Feature_schemas.Bar_row.t) b ->
            String.compare a.bar_type b.bar_type)
        in
        write Feature_schemas.bars (bars_path ~dir instrument date) rows >>| Option.some)
    in
    let%map toxicity =
      match bucket with
      | None -> return None
      | Some bucket ->
        let%map path, rows =
          write
            Feature_schemas.toxicity
            (toxicity_path ~dir instrument date)
            (List.rev !tox_rows)
        in
        Some (path, rows, bucket)
    in
    Some { Result.instrument; trades; bars; toxicity }
;;

let run ?instruments ?toxicity ~dir ~bars date =
  let%bind instruments =
    match instruments with
    | Some l -> return l
    | None -> Store.instruments (Store.create dir)
  in
  Deferred.List.filter_map instruments ~how:`Sequential ~f:(fun instrument ->
    instrument_day ?toxicity ~dir ~bars instrument date)
;;

let spec_arg = Command.Arg_type.create (fun s -> Bars.Spec.of_string s |> Or_error.ok_exn)

let classification_arg =
  Command.Arg_type.create (fun s ->
    Toxicity.Classification.of_string s |> Or_error.ok_exn)
;;

let default_bars = [ "tick:1000"; "volume-imbalance:1000" ]

let command =
  Command.async
    ~summary:"Write bars and VPIN toxicity Parquet tables from a day of norm/ trades"
    ~readme:(fun () ->
      String.concat
        ~sep:"\n"
        [ "For each instrument with a trades event log on DATE, writes"
        ; "  <dir>/<venue>/<symbol>/parquet/bars/<date>.parquet"
        ; "  <dir>/<venue>/<symbol>/parquet/toxicity/<date>.parquet"
        ; ""
        ; "Bar specs: tick:N, volume:SIZE, dollar:X, and \
           <tick|volume|dollar>-imbalance:N or"
        ; "<tick|volume|dollar>-run:N with N warm-up trades. Default: "
          ^ String.concat ~sep:" " default_bars
          ^ "."
        ; "Classification: aggressor (default), tick-rule, or bulk-<span> such as \
           bulk-1m."
        ])
    (let%map_open.Command dir =
       flag "-dir" (required string) ~doc:"DIR store root (<DIR>/<venue>/<symbol>/norm/)"
     and date = flag "-date" (required date) ~doc:"YYYY-MM-DD the UTC day"
     and instruments =
       flag
         "-instrument"
         (listed string)
         ~doc:"venue:SYMBOL only this instrument (repeatable; default all)"
     and bars = flag "-bars" (listed spec_arg) ~doc:"SPEC a bar kind (repeatable)"
     and no_bars = flag "-no-bars" no_arg ~doc:" write no bars table"
     and bucket =
       flag "-bucket" (optional string) ~doc:"SIZE fixed toxicity bucket volume"
     and buckets_per_day =
       flag
         "-buckets-per-day"
         (optional_with_default 50 int)
         ~doc:"N toxicity buckets per day when -bucket is not given (default 50)"
     and window =
       flag
         "-window"
         (optional_with_default 50 int)
         ~doc:"N buckets per VPIN (default 50)"
     and zscore_window =
       flag
         "-zscore-window"
         (optional_with_default 250 int)
         ~doc:"N previous VPIN values for the z-score (default 250)"
     and classification =
       flag
         "-classification"
         (optional_with_default Toxicity.Classification.Aggressor classification_arg)
         ~doc:"C aggressor, tick-rule or bulk-<span> (default aggressor)"
     and no_toxicity = flag "-no-toxicity" no_arg ~doc:" write no toxicity table" in
     fun () ->
       let bars =
         if no_bars
         then []
         else if List.is_empty bars
         then List.map default_bars ~f:(fun s -> Bars.Spec.of_string s |> ok_exn)
         else bars
       in
       let toxicity =
         if no_toxicity
         then None
         else
           Some
             { Toxicity_spec.bucket =
                 (match bucket with
                  | Some s -> Fixed (Size.of_string s)
                  | None -> Per_day buckets_per_day)
             ; window
             ; zscore_window
             ; classification
             }
       in
       let instruments =
         match instruments with
         | [] -> None
         | l -> Some (List.map l ~f:Instrument.of_string)
       in
       let%map results = run ?instruments ?toxicity ~dir ~bars date in
       List.iter results ~f:(fun r ->
         printf "%s: %d trades\n" (Instrument.to_string r.instrument) r.trades;
         Option.iter r.bars ~f:(fun (path, rows) ->
           printf "  wrote %s (%d bars)\n" path rows);
         Option.iter r.toxicity ~f:(fun (path, rows, bucket) ->
           printf "  wrote %s (%d buckets of %s)\n" path rows (Size.to_string bucket))))
;;
