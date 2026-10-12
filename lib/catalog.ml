open! Core
open! Async

module Entry = struct
  type t =
    { table : Parquet_kind.t
    ; venues : Venue.t list
    ; instruments : int
    ; first_date : Date.t
    ; last_date : Date.t
    ; files : int
    ; parts : string list
    }
  [@@deriving sexp_of, compare, equal]
end

(* [<date>.parquet] is [`Day date], [<date>.<n>.parquet] is [`Part date]. *)
let parse_name name =
  match String.chop_suffix name ~suffix:".parquet" with
  | None -> None
  | Some stem ->
    let date s = Option.try_with (fun () -> Date.of_string s) in
    (match String.lsplit2 stem ~on:'.' with
     | None -> Option.map (date stem) ~f:(fun d -> `Day d)
     | Some (d, n) when (not (String.is_empty n)) && String.for_all n ~f:Char.is_digit ->
       Option.map (date d) ~f:(fun d -> `Part d)
     | Some _ -> None)
;;

let ls dir =
  match%bind Sys.is_directory_exn dir with
  | false -> return []
  | true -> Sys.readdir dir >>| Array.to_list >>| List.sort ~compare:String.compare
;;

let scan ~dir =
  let%bind instruments = Store.instruments (Store.create dir) in
  Deferred.List.filter_map Parquet_kind.all ~how:`Sequential ~f:(fun table ->
    let%map per_instrument =
      Deferred.List.filter_map instruments ~how:`Sequential ~f:(fun instrument ->
        let kind_dir = Parquet_kind.kind_dir ~dir instrument table in
        let%map names = ls kind_dir in
        match
          List.filter_map names ~f:(fun n ->
            Option.map (parse_name n) ~f:(Tuple2.create n))
        with
        | [] -> None
        | files -> Some (instrument, kind_dir, files))
    in
    match per_instrument with
    | [] -> None
    | _ ->
      let all = List.concat_map per_instrument ~f:(fun (_, _, files) -> files) in
      let dates = List.map all ~f:(fun (_, (`Day d | `Part d)) -> d) in
      let parts =
        List.concat_map per_instrument ~f:(fun (_, kind_dir, files) ->
          List.filter_map files ~f:(function
            | name, `Part _ ->
              let path = kind_dir ^/ name in
              Some
                (Option.value (String.chop_prefix path ~prefix:(dir ^ "/")) ~default:path)
            | _, `Day _ -> None))
      in
      Some
        { Entry.table
        ; venues =
            List.map per_instrument ~f:(fun (i, _, _) -> Instrument.venue i)
            |> List.dedup_and_sort ~compare:Venue.compare
        ; instruments = List.length per_instrument
        ; first_date = Option.value_exn (List.min_elt dates ~compare:Date.compare)
        ; last_date = Option.value_exn (List.max_elt dates ~compare:Date.compare)
        ; files = List.length all
        ; parts
        })
;;

let to_string_hum entries =
  let header = [ "table"; "venues"; "symbols"; "first"; "last"; "files"; "parts" ] in
  let rows =
    List.map entries ~f:(fun (e : Entry.t) ->
      [ Parquet_kind.to_string e.table
      ; String.concat ~sep:"," (List.map e.venues ~f:Venue.to_string)
      ; Int.to_string e.instruments
      ; Date.to_string e.first_date
      ; Date.to_string e.last_date
      ; Int.to_string e.files
      ; Int.to_string (List.length e.parts)
      ])
  in
  let widths =
    List.fold
      (header :: rows)
      ~init:(List.map header ~f:(Fn.const 0))
      ~f:(fun acc row -> List.map2_exn acc row ~f:(fun w c -> max w (String.length c)))
  in
  let line row =
    List.map2_exn row widths ~f:(fun c w -> c ^ String.make (w - String.length c) ' ')
    |> String.concat ~sep:"  "
    |> String.rstrip
  in
  let parts =
    List.concat_map entries ~f:(fun e -> e.parts)
    |> List.map ~f:(fun p -> "leftover part: " ^ p)
  in
  String.concat ~sep:"\n" ((line header :: List.map rows ~f:line) @ parts) ^ "\n"
;;
