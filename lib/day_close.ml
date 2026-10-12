open! Core
module Md_stream = Stream
open! Async

module Outcome = struct
  type t =
    | Written of
        { rows : int
        ; tail : Framed.Tail.t
        }
    | Up_to_date
    | No_source
  [@@deriving sexp_of, compare, equal]
end

module Result = struct
  type t =
    { instrument : Instrument.t
    ; kind : Parquet_kind.t
    ; path : string
    ; outcome : Outcome.t
    }
  [@@deriving sexp_of]
end

module Manifest = struct
  let code_version = "day-close-1 events-" ^ Event_log.digest

  module Input = struct
    type t =
      { path : string
      ; size : int
      ; mtime : float
      }
    [@@deriving sexp, compare, equal]
  end

  type t =
    { inputs : Input.t list
    ; output : string
    ; output_bytes : int
    ; rows : int
    ; code_version : string
    }
  [@@deriving sexp, compare, equal]

  let path target =
    String.chop_suffix_if_exists target ~suffix:".parquet" ^ ".manifest.sexp"
  ;;

  let relative ~dir path =
    Option.value (String.chop_prefix path ~prefix:(dir ^ "/")) ~default:path
  ;;

  let stat path =
    match%bind Sys.file_exists_exn path with
    | false -> return None
    | true -> Unix.stat path >>| Option.some
  ;;

  let input ~dir path =
    match%map stat path with
    | None -> None
    | Some (stat : Unix.Stats.t) ->
      Some
        { Input.path = relative ~dir path
        ; size = Int64.to_int_exn stat.size
        ; mtime = Time_float.Span.to_sec (Time_float.to_span_since_epoch stat.mtime)
        }
  ;;

  let load target =
    let path = path target in
    match%bind Sys.file_exists_exn path with
    | false -> return None
    | true ->
      (match%map Monitor.try_with (fun () -> Reader.load_sexp_exn path t_of_sexp) with
       | Ok t -> Some t
       | Error _ -> None)
  ;;

  let save target t = Writer.save_sexp ~hum:true (path target) (sexp_of_t t)

  let matches t ~inputs =
    String.equal t.code_version code_version && [%equal: Input.t list] t.inputs inputs
  ;;
end

(* Parts [<date>.<n>.parquet] written by a restarted sink. *)
let remove_parts target =
  let dir = Filename.dirname target in
  let stem = Filename.basename target |> String.chop_suffix_exn ~suffix:".parquet" in
  let%bind names = Sys.readdir dir in
  Array.to_list names
  |> List.filter ~f:(fun name ->
    match String.chop_prefix name ~prefix:(stem ^ ".") with
    | None -> false
    | Some rest ->
      (match String.chop_suffix rest ~suffix:".parquet" with
       | Some n -> String.for_all n ~f:Char.is_digit && not (String.is_empty n)
       | None -> false))
  |> Deferred.List.iter ~how:`Sequential ~f:(fun name -> Unix.unlink (dir ^/ name))
;;

(* Streams [source] into [target], [f] turning each chunk of events into rows. [finish]
   yields rows to append once the source is exhausted. *)
let convert ?compression ~row_group_rows ~schema ~source ~target ~f ~finish () =
  let%bind file = Parquet_file.create ?compression schema ~row_group_rows target in
  let events, tail = Event_log.read_file source in
  let%bind () =
    Pipe.iter' events ~f:(fun chunk -> Parquet_file.add file (f (Queue.to_list chunk)))
  in
  let%bind () = Parquet_file.add file (finish ()) in
  let rows = Parquet_file.num_rows file in
  let%bind () = Parquet_file.close file in
  let%bind () = remove_parts target in
  let%map tail in
  Outcome.Written { rows; tail }
;;

let table ?compression ~row_group_rows ~candle_interval ~force ~dir instrument date kind =
  let source_stream : Md_stream.t =
    match (kind : Parquet_kind.t) with
    | Trades | Candles -> Trades
    | Bbo -> Bbo
    | L2 -> L2
    | Funding -> Funding
  in
  let source = Event_log.path ~dir instrument source_stream date in
  let target = Parquet_kind.path ~dir instrument kind date in
  let%bind input = Manifest.input ~dir source in
  let%bind manifest = Manifest.load target in
  let%bind target_exists = Sys.file_exists_exn target in
  let%map outcome =
    match input, manifest with
    | None, _ -> return Outcome.No_source
    | Some input, Some m
      when (not force) && target_exists && Manifest.matches m ~inputs:[ input ] ->
      return Outcome.Up_to_date
    | Some input, _ ->
      let%bind outcome =
        let convert schema ~f ~finish =
          convert ?compression ~row_group_rows ~schema ~source ~target ~f ~finish ()
        in
        let no_more () = [] in
        match kind with
        | Trades ->
          convert
            Parquet_schemas.trade
            ~f:
              (List.filter_map ~f:(function
                | Event.Trade t -> Some t
                | _ -> None))
            ~finish:no_more
        | Bbo ->
          convert
            Parquet_schemas.bbo
            ~f:
              (List.filter_map ~f:(function
                | Event.Bbo b -> Some b
                | _ -> None))
            ~finish:no_more
        | Funding ->
          convert
            Parquet_schemas.funding
            ~f:
              (List.filter_map ~f:(function
                | Event.Funding x -> Some x
                | _ -> None))
            ~finish:no_more
        | L2 ->
          let seq = ref 0 in
          convert
            Parquet_schemas.l2
            ~f:
              (List.concat_map ~f:(function
                | Event.L2 u ->
                  let rows = Parquet_schemas.L2_row.of_update ~seq:!seq u in
                  incr seq;
                  rows
                | _ -> []))
            ~finish:no_more
        | Candles ->
          let agg = Candle_agg.create instrument ~interval:candle_interval in
          convert
            Parquet_schemas.candle
            ~f:
              (List.concat_map ~f:(function
                | Event.Trade t -> Candle_agg.add agg t
                | _ -> []))
            ~finish:(fun () -> Option.to_list (Candle_agg.current agg))
      in
      let%bind output = Manifest.stat target in
      let%map () =
        match outcome with
        | Written { rows; tail = _ } ->
          Manifest.save
            target
            { inputs = [ input ]
            ; output = Manifest.relative ~dir target
            ; output_bytes =
                Option.value_map output ~default:0 ~f:(fun (s : Unix.Stats.t) ->
                  Int64.to_int_exn s.size)
            ; rows
            ; code_version = Manifest.code_version
            }
        | Up_to_date | No_source -> return ()
      in
      outcome
  in
  { Result.instrument; kind; path = target; outcome }
;;

let run
  ?compression
  ?(row_group_rows = 1_048_576)
  ?(candle_interval = Time_ns.Span.minute)
  ?(force = false)
  ?instruments
  ~dir
  date
  =
  let%bind instruments =
    match instruments with
    | Some l -> return l
    | None -> Store.instruments (Store.create dir)
  in
  Deferred.List.concat_map instruments ~how:`Sequential ~f:(fun instrument ->
    Deferred.List.map Parquet_kind.all ~how:`Sequential ~f:(fun kind ->
      table ?compression ~row_group_rows ~candle_interval ~force ~dir instrument date kind))
;;
