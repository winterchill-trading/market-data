open! Core
module Md_stream = Stream
open! Async

module Line = struct
  type t =
    | Frame of
        { recv_ts : Time_ns.Alternate_sexp.t
        ; payload : string
        }
    | Disconnect
  [@@deriving sexp_of, compare, equal]

  let parse line =
    if String.is_empty line
    then Ok Disconnect
    else (
      match String.lsplit2 line ~on:' ' with
      | None ->
        Or_error.error_s [%message "Raw_minute: no space after the timestamp" line]
      | Some (ts, payload) ->
        (match Time_ns.of_string_with_utc_offset ts with
         | recv_ts -> Ok (Frame { recv_ts; payload })
         | exception _ ->
           Or_error.error_s [%message "Raw_minute: bad timestamp" (ts : string)]))
  ;;
end

module File = struct
  type t =
    { venue : Venue.t
    ; stream : Md_stream.t
    ; symbol_dir : string
    ; minute : Time_ns.Alternate_sexp.t
    ; compressed : bool
    ; path : string
    }
  [@@deriving sexp_of, compare]

  let of_path path =
    let parts = String.split path ~on:'/' |> List.rev in
    match parts with
    | name :: dd :: mm :: yyyy :: symbol_dir :: stream :: venue :: _ ->
      Or_error.try_with (fun () ->
        let stem, compressed =
          match String.chop_suffix name ~suffix:".ndjson.zst" with
          | Some stem -> stem, true
          | None -> String.chop_suffix_exn name ~suffix:".ndjson", false
        in
        let hh, mi =
          match String.split stem ~on:'-' with
          | [ hh; mi ] -> Int.of_string hh, Int.of_string mi
          | _ -> failwith "minute file name is not <HH>-<MM>"
        in
        let date =
          Date.create_exn
            ~y:(Int.of_string yyyy)
            ~m:(Month.of_int_exn (Int.of_string mm))
            ~d:(Int.of_string dd)
        in
        let minute =
          Time_ns.of_date_ofday
            ~zone:Time_float.Zone.utc
            date
            (Time_ns.Ofday.create ~hr:hh ~min:mi ())
        in
        { venue = Venue.of_string venue
        ; stream = Md_stream.of_string stream
        ; symbol_dir
        ; minute
        ; compressed
        ; path
        })
      |> Or_error.tag_s ~tag:[%message "Raw_minute: not a minute file" path]
    | _ -> Or_error.error_s [%message "Raw_minute: not a minute file" path]
  ;;
end

let max_decompressed = 1 lsl 32

let decompress data =
  let rec go size =
    match Zstd.decompress size data with
    | s -> s
    | exception Zstd.Error msg
      when String.is_substring msg ~substring:"too small" && size < max_decompressed ->
      go (size * 2)
  in
  let first =
    try Zstd.get_decompressed_size data with
    | _ -> 0
  in
  go (Int.max 4096 (Int.max first (4 * String.length data)))
;;

let read_lines_blocking path =
  let data = In_channel.read_all path in
  let text = if String.is_suffix path ~suffix:".zst" then decompress data else data in
  let lines = String.split text ~on:'\n' in
  (* A final newline leaves an empty last element that is not a disconnect. *)
  match List.last lines with
  | Some "" -> List.drop_last_exn lines
  | _ -> lines
;;

let read path =
  In_thread.run (fun () ->
    Or_error.try_with_join (fun () ->
      read_lines_blocking path |> List.map ~f:Line.parse |> Or_error.combine_errors))
  >>| Or_error.tag ~tag:path
;;

let ls dir =
  match%bind Sys.is_directory_exn dir with
  | false -> return []
  | true ->
    let%map names = Sys.readdir dir in
    Array.to_list names |> List.sort ~compare:String.compare
;;

let files ~data_dir date =
  let raw = data_dir ^/ "raw" in
  let day_dir =
    sprintf
      "%04d/%02d/%02d"
      (Date.year date)
      (Month.to_int (Date.month date))
      (Date.day date)
  in
  let%bind venues = ls raw in
  let%map paths =
    Deferred.List.concat_map venues ~how:`Sequential ~f:(fun venue ->
      let%bind streams = ls (raw ^/ venue) in
      Deferred.List.concat_map streams ~how:`Sequential ~f:(fun stream ->
        let%bind symbols = ls (raw ^/ venue ^/ stream) in
        Deferred.List.concat_map symbols ~how:`Sequential ~f:(fun symbol ->
          let dir = raw ^/ venue ^/ stream ^/ symbol ^/ day_dir in
          let%map names = ls dir in
          List.map names ~f:(fun name -> dir ^/ name))))
  in
  List.filter_map paths ~f:(fun path -> Result.ok (File.of_path path))
  |> List.sort ~compare:(fun (a : File.t) (b : File.t) ->
    [%compare: Venue.t * Md_stream.t * string * Time_ns.t * bool]
      (a.venue, a.stream, a.symbol_dir, a.minute, not a.compressed)
      (b.venue, b.stream, b.symbol_dir, b.minute, not b.compressed))
;;
