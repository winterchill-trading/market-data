open! Core
module Md_stream = Stream
open! Async

module Stats = struct
  type t =
    { files : int
    ; frames : int
    ; disconnects : int
    ; events : int
    ; frame_errors : int
    ; first_errors : Error.t list
    ; skipped_files : int
    ; skipped_venues : Venue.t list
    }
  [@@deriving sexp_of]
end

let max_errors = 10

let check_out_dir out_dir =
  match%bind Sys.file_exists_exn out_dir with
  | false -> return (Ok ())
  | true ->
    let%map names = Sys.readdir out_dir in
    if Array.is_empty names
    then Ok ()
    else
      Or_error.error_s
        [%message
          "Rebuild_norm: output directory is not empty; event logs would be appended to"
            (out_dir : string)]
;;

let run ~normalizers ~data_dir ~out_dir date =
  match%bind check_out_dir out_dir with
  | Error _ as e -> return e
  | Ok () ->
    let%bind files = Raw_minute.files ~data_dir date in
    let normalizer venue =
      List.find normalizers ~f:(fun n -> Venue.equal (Normalizer.venue n) venue)
    in
    let writer = Event_log.Writer.create ~dir:out_dir () in
    let frames = ref 0
    and disconnects = ref 0
    and events = ref 0
    and frame_errors = ref 0
    and first_errors = ref []
    and skipped_files = ref 0
    and skipped_venues = ref Venue.Set.empty in
    let note_error e =
      incr frame_errors;
      if List.length !first_errors < max_errors then first_errors := e :: !first_errors
    in
    let series =
      List.group files ~break:(fun (a : Raw_minute.File.t) b ->
        not
          (Venue.equal a.venue b.venue
           && Md_stream.equal a.stream b.stream
           && String.equal a.symbol_dir b.symbol_dir))
    in
    let%bind result =
      Deferred.Or_error.List.iter series ~how:`Sequential ~f:(fun files ->
        let venue = (List.hd_exn files).venue in
        match normalizer venue with
        | None ->
          skipped_files := !skipped_files + List.length files;
          skipped_venues := Set.add !skipped_venues venue;
          Deferred.Or_error.ok_unit
        | Some (module N) ->
          let state = N.create () in
          Deferred.Or_error.List.iter files ~how:`Sequential ~f:(fun file ->
            let%map.Deferred.Or_error lines = Raw_minute.read file.path in
            List.iter lines ~f:(function
              | Disconnect ->
                incr disconnects;
                N.disconnect state
              | Frame { recv_ts; payload } ->
                incr frames;
                (match N.frame state ~recv_ts payload with
                 | Ok evs ->
                   events := !events + List.length evs;
                   List.iter evs ~f:(Event_log.Writer.append writer)
                 | Error e ->
                   note_error
                     (Error.tag_s
                        e
                        ~tag:
                          [%message
                            ""
                              ~file:
                                (Option.value
                                   (String.chop_prefix file.path ~prefix:(data_dir ^ "/"))
                                   ~default:file.path
                                 : string)])))))
    in
    let%map () = Event_log.Writer.close writer in
    Or_error.map result ~f:(fun () ->
      { Stats.files = List.length files
      ; frames = !frames
      ; disconnects = !disconnects
      ; events = !events
      ; frame_errors = !frame_errors
      ; first_errors = List.rev !first_errors
      ; skipped_files = !skipped_files
      ; skipped_venues = Set.to_list !skipped_venues
      })
;;

let command normalizers =
  Command.async_or_error
    ~summary:"Rebuild a day of norm/ event logs from raw minute files"
    ~readme:(fun () ->
      sprintf
        "Reads <data-dir>/raw/<venue>/<stream>/<symbol>/<YYYY>/<MM>/<DD>/*.ndjson[.zst] \
         and writes <out>/<venue>/<symbol>/norm/<stream>/<date>.bin.\n\
         Venues with a normalizer in this binary: %s."
        (match normalizers with
         | [] -> "none (link a feed library's Normalizer.S to add one)"
         | l ->
           List.map l ~f:(fun n -> Venue.to_string (Normalizer.venue n))
           |> String.concat ~sep:", "))
    (let%map_open.Command data_dir =
       flag "-data-dir" (required string) ~doc:"DIR recorder data directory (holds raw/)"
     and out_dir =
       flag
         "-out"
         (required string)
         ~doc:"DIR where to write the event logs (new or empty)"
     and date = flag "-date" (required date) ~doc:"YYYY-MM-DD UTC day to rebuild" in
     fun () ->
       let%map.Deferred.Or_error stats = run ~normalizers ~data_dir ~out_dir date in
       Core.print_s [%sexp (stats : Stats.t)])
;;
