open! Core
module Md_stream = Stream
open! Async

module Item = struct
  type t =
    | Frame of
        { recv_ts : Time_ns.Alternate_sexp.t
        ; stream : Md_stream.t
        ; frame : string
        }
    | Gap of
        { recv_ts : Time_ns.Alternate_sexp.t
        ; stream : Md_stream.t
        }
  [@@deriving sexp_of, compare, equal]

  let recv_ts = function
    | Frame { recv_ts; _ } | Gap { recv_ts; _ } -> recv_ts
  ;;

  let stream = function
    | Frame { stream; _ } | Gap { stream; _ } -> stream
  ;;
end

let symbol_dir symbol =
  String.map symbol ~f:(function
    | '/' | '\\' | ' ' -> '_'
    | c -> c)
;;

let ls dir =
  match%bind Sys.is_directory_exn dir with
  | false -> return []
  | true ->
    let%map names = Sys.readdir dir in
    Array.to_list names |> List.sort ~compare:String.compare
;;

let streams ~data_dir ~venue ~symbol =
  let venue_dir = data_dir ^/ "raw" ^/ Venue.to_string venue in
  let%bind names = ls venue_dir in
  let%map present =
    Deferred.List.filter names ~how:`Sequential ~f:(fun name ->
      Sys.is_directory_exn (venue_dir ^/ name ^/ symbol_dir symbol))
  in
  List.filter_map present ~f:Md_stream.of_string_opt
  |> List.dedup_and_sort ~compare:Md_stream.compare
;;

let minute_ns = Time_ns.Span.to_int_ns Time_ns.Span.minute

let floor_minute t =
  let ns = Time_ns.to_int_ns_since_epoch t in
  Time_ns.of_int_ns_since_epoch (ns - Int.( % ) ns minute_ns)
;;

let minute_files ~data_dir ~venue ~stream ~symbol ~start ~stop =
  if Time_ns.( >= ) start stop
  then return []
  else (
    let zone = Time_float.Zone.utc in
    let dates =
      Date.dates_between
        ~min:(Time_ns.to_date start ~zone)
        ~max:(Time_ns.to_date (Time_ns.sub stop Time_ns.Span.nanosecond) ~zone)
    in
    let series_dir =
      data_dir
      ^/ "raw"
      ^/ Venue.to_string venue
      ^/ Md_stream.to_string stream
      ^/ symbol_dir symbol
    in
    let first = floor_minute start in
    let%map paths =
      Deferred.List.concat_map dates ~how:`Sequential ~f:(fun date ->
        let dir =
          sprintf
            "%s/%04d/%02d/%02d"
            series_dir
            (Date.year date)
            (Month.to_int (Date.month date))
            (Date.day date)
        in
        let%map names = ls dir in
        List.map names ~f:(fun name -> dir ^/ name))
    in
    List.filter_map paths ~f:(fun path -> Result.ok (Raw_minute.File.of_path path))
    |> List.filter ~f:(fun (f : Raw_minute.File.t) ->
      Time_ns.( >= ) f.minute first && Time_ns.( < ) f.minute stop)
    |> List.stable_sort ~compare:(fun (a : Raw_minute.File.t) b ->
      [%compare: Time_ns.t * bool]
        (a.minute, not a.compressed)
        (b.minute, not b.compressed)))
;;

let default_on_error e = Log.Global.error_s (Error.sexp_of_t e)

let of_files ?(on_error = default_on_error) ?range ~stream files =
  let in_range =
    match range with
    | None -> fun _ -> true
    | Some (start, stop) -> fun t -> Time_ns.( >= ) t start && Time_ns.( < ) t stop
  in
  Pipe.create_reader ~close_on_exception:true (fun w ->
    let last = ref None in
    Deferred.List.iter files ~how:`Sequential ~f:(fun (file : Raw_minute.File.t) ->
      if Pipe.is_closed w
      then return ()
      else (
        match%bind
          In_thread.run (fun () ->
            Or_error.try_with (fun () -> Raw_minute.read_lines_blocking file.path))
        with
        | Error e ->
          on_error (Error.tag e ~tag:file.path);
          return ()
        | Ok lines ->
          (* A gap at the start of a file sorts at the file's minute, not before it. *)
          last
          := Some
               (Option.value_map !last ~default:file.minute ~f:(Time_ns.max file.minute));
          let items = Queue.create () in
          List.iter lines ~f:(fun line ->
            match Raw_minute.Line.parse line with
            | Error e -> on_error (Error.tag e ~tag:file.path)
            | Ok (Frame { recv_ts; payload }) ->
              last := Some recv_ts;
              if in_range recv_ts
              then Queue.enqueue items (Item.Frame { recv_ts; stream; frame = payload })
            | Ok Disconnect ->
              let recv_ts = Option.value_exn !last in
              if in_range recv_ts then Queue.enqueue items (Item.Gap { recv_ts; stream }));
          if Pipe.is_closed w then return () else Pipe.transfer_in w ~from:items)))
;;

let read ?on_error ?streams:wanted ~data_dir ~venue ~symbol ~start ~stop () =
  let range = start, stop in
  Pipe.create_reader ~close_on_exception:true (fun w ->
    let%bind streams =
      match wanted with
      | Some l -> return l
      | None -> streams ~data_dir ~venue ~symbol
    in
    let%bind inputs =
      Deferred.List.map streams ~how:`Sequential ~f:(fun stream ->
        let%map files = minute_files ~data_dir ~venue ~stream ~symbol ~start ~stop in
        of_files ?on_error ~range ~stream files)
    in
    let merged =
      Merge.sorted inputs ~compare:(fun a b ->
        Time_ns.compare (Item.recv_ts a) (Item.recv_ts b))
    in
    upon (Pipe.closed w) (fun () -> Pipe.close_read merged);
    Pipe.transfer_id merged w)
;;
