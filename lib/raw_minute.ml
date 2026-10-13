open! Core
module Md_stream = Stream
open! Async

(* The recorder's timestamp, [YYYY-MM-DDTHH:MM:SS], an optional fraction of 1 to 9 digits
   and [Z], parsed in place to nanoseconds since the epoch; [not_fast] for anything else
   (other offsets, leap seconds, years outside 1970-2099), which falls back to
   [Time_ns.of_string_with_utc_offset]. *)
module Fast_ts = struct
  let not_fast = Int.min_value

  let[@inline] digit s i =
    let c = Char.to_int (String.unsafe_get s i) - Char.to_int '0' in
    if c >= 0 && c <= 9 then c else -1000
  ;;

  let[@inline] two s i = (digit s i * 10) + digit s (i + 1)

  let[@inline] four s i =
    (digit s i * 1000) + (digit s (i + 1) * 100) + (digit s (i + 2) * 10) + digit s (i + 3)
  ;;

  let[@inline] is_leap y = (y % 4 = 0 && y % 100 <> 0) || y % 400 = 0

  let[@inline] days_in_month y m =
    match m with
    | 2 -> if is_leap y then 29 else 28
    | 4 | 6 | 9 | 11 -> 30
    | _ -> 31
  ;;

  (* Days from 1970-01-01 to [y]-[m]-[d], for [y >= 1970]. *)
  let days_from_civil y m d =
    let y = if m <= 2 then y - 1 else y in
    let era = y / 400 in
    let yoe = y - (era * 400) in
    let mp = if m > 2 then m - 3 else m + 9 in
    let doy = (((153 * mp) + 2) / 5) + d - 1 in
    let doe = (yoe * 365) + (yoe / 4) - (yoe / 100) + doy in
    (era * 146097) + doe - 719468
  ;;

  let parse s ~pos ~len =
    if len < 20
       || Char.( <> ) (String.unsafe_get s (pos + 4)) '-'
       || Char.( <> ) (String.unsafe_get s (pos + 7)) '-'
       || Char.( <> ) (String.unsafe_get s (pos + 10)) 'T'
       || Char.( <> ) (String.unsafe_get s (pos + 13)) ':'
       || Char.( <> ) (String.unsafe_get s (pos + 16)) ':'
       || Char.( <> ) (String.unsafe_get s (pos + len - 1)) 'Z'
    then not_fast
    else (
      let y = four s pos in
      let mo = two s (pos + 5) in
      let d = two s (pos + 8) in
      let h = two s (pos + 11) in
      let mi = two s (pos + 14) in
      let sec = two s (pos + 17) in
      if y < 1970
         || y > 2099
         || mo < 1
         || mo > 12
         || d < 1
         || d > days_in_month y mo
         || h < 0
         || h > 23
         || mi < 0
         || mi > 59
         || sec < 0
         || sec > 59
      then not_fast
      else (
        (* [len = 20]: no fraction. Otherwise [.] and 1 to 9 digits before [Z]. *)
        let frac_digits = len - 21 in
        let frac =
          if len = 20
          then 0
          else if Char.( <> ) (String.unsafe_get s (pos + 19)) '.'
                  || frac_digits < 1
                  || frac_digits > 9
          then -1
          else (
            let mutable acc = 0 in
            let mutable ok = true in
            for i = 0 to 8 do
              let c = if i < frac_digits then digit s (pos + 20 + i) else 0 in
              if c < 0 then ok <- false;
              acc <- (acc * 10) + c
            done;
            if ok then acc else -1)
        in
        if frac < 0
        then not_fast
        else
          (((((((days_from_civil y mo d * 24) + h) * 60) + mi) * 60) + sec)
           * 1_000_000_000)
          + frac))
  ;;
end

module Line = struct
  type t =
    | Frame of
        { recv_ts : Time_ns.Alternate_sexp.t
        ; payload : string
        }
    | Disconnect
  [@@deriving sexp_of, compare, equal]

  let parse_ts_slow s ~pos ~len =
    let ts = String.sub s ~pos ~len in
    match Time_ns.of_string_with_utc_offset ts with
    | recv_ts -> Ok recv_ts
    | exception _ -> Or_error.error_s [%message "Raw_minute: bad timestamp" (ts : string)]
  ;;

  (* The timestamp of a line [s.[pos .. pos + len)] ending at its first space [sp]. *)
  let parse_ts s ~pos ~sp =
    let ns = Fast_ts.parse s ~pos ~len:(sp - pos) in
    if ns = Fast_ts.not_fast
    then parse_ts_slow s ~pos ~len:(sp - pos)
    else Ok (Time_ns.of_int_ns_since_epoch ns)
  ;;

  let no_space s ~pos ~len =
    let line = String.sub s ~pos ~len in
    Or_error.error_s [%message "Raw_minute: no space after the timestamp" line]
  ;;

  let parse_sub s ~pos ~len =
    if len = 0
    then Ok Disconnect
    else (
      match String.index_from s pos ' ' with
      | Some sp when sp < pos + len ->
        (match parse_ts s ~pos ~sp with
         | Ok recv_ts ->
           Ok
             (Frame
                { recv_ts
                ; payload = String.sub s ~pos:(sp + 1) ~len:(pos + len - sp - 1)
                })
         | Error _ as e -> e)
      | _ -> no_space s ~pos ~len)
  ;;

  let parse line = parse_sub line ~pos:0 ~len:(String.length line)
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

let read_text_blocking path =
  let data = In_channel.read_all path in
  if String.is_suffix path ~suffix:".zst" then decompress data else data
;;

let iter_lines text ~f =
  let n = String.length text in
  let mutable pos = 0 in
  while pos < n do
    let eol =
      match String.index_from text pos '\n' with
      | Some i -> i
      | None -> n
    in
    f ~pos ~len:(eol - pos);
    pos <- eol + 1
  done
;;

let iter_text text ~frame ~disconnect ~error =
  iter_lines text ~f:(fun ~pos ~len ->
    if len = 0
    then disconnect ()
    else (
      let sp = String.index_from text pos ' ' in
      match sp with
      | Some sp when sp < pos + len ->
        (match Line.parse_ts text ~pos ~sp with
         | Ok recv_ts ->
           frame
             ~recv_ts
             ~payload:(String.sub text ~pos:(sp + 1) ~len:(pos + len - sp - 1))
         | Error e -> error e)
      | _ ->
        (match Line.no_space text ~pos ~len with
         | Error e -> error e
         | Ok _ -> assert false)))
;;

let read_lines_blocking path =
  let text = read_text_blocking path in
  let lines = String.split text ~on:'\n' in
  (* A final newline leaves an empty last element that is not a disconnect. *)
  match List.last lines with
  | Some "" -> List.drop_last_exn lines
  | _ -> lines
;;

let read path =
  In_thread.run (fun () ->
    Or_error.try_with_join (fun () ->
      let text = read_text_blocking path in
      let lines = ref [] in
      iter_lines text ~f:(fun ~pos ~len ->
        lines := Line.parse_sub text ~pos ~len :: !lines);
      List.rev !lines |> Or_error.combine_errors))
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
