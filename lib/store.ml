open! Core

module Layer = struct
  type t =
    | Raw
    | Norm
  [@@deriving sexp, compare, equal, enumerate]

  let to_string = function
    | Raw -> "raw"
    | Norm -> "norm"
  ;;

  let extension = function
    | Raw -> ".binlog"
    | Norm -> ".bin"
  ;;
end

type t = { root : string } [@@deriving sexp_of]

let create root = { root }
let root t = t.root
let date_of_time time = Time_ns.to_date time ~zone:Time_float.Zone.utc

let instrument_dir t instrument =
  String.concat
    ~sep:"/"
    [ t.root
    ; Venue.to_string (Instrument.venue instrument)
    ; Symbol.to_string (Instrument.symbol instrument)
    ]
;;

let stream_dir t layer instrument stream =
  String.concat
    ~sep:"/"
    [ instrument_dir t instrument; Layer.to_string layer; Stream.to_string stream ]
;;

let path t layer instrument stream date =
  stream_dir t layer instrument stream ^ "/" ^ Date.to_string date ^ Layer.extension layer
;;

let ls dir =
  let open Async in
  match%bind Sys.is_directory_exn dir with
  | false -> return []
  | true -> Sys.readdir dir >>| Array.to_list
;;

let days t layer instrument stream =
  let open Async in
  let%map names = ls (stream_dir t layer instrument stream) in
  List.filter_map names ~f:(fun name ->
    let%bind.Option base = String.chop_suffix name ~suffix:(Layer.extension layer) in
    Option.try_with (fun () -> Date.of_string base))
  |> List.dedup_and_sort ~compare:Date.compare
;;

let instruments t =
  let open Async in
  let%bind venues = ls t.root in
  let%map per_venue =
    Deferred.List.map
      ~how:`Sequential
      (List.filter_map venues ~f:Venue.of_string_opt)
      ~f:(fun venue ->
        let%map symbols = ls (t.root ^/ Venue.to_string venue) in
        List.map symbols ~f:(Instrument.create venue))
  in
  List.concat per_venue |> List.sort ~compare:Instrument.compare
;;

let files t layer instrument streams ~from ~to_ =
  let open Async in
  let dates = Date.dates_between ~min:from ~max:to_ in
  let candidates =
    List.concat_map dates ~f:(fun date ->
      List.map streams ~f:(fun stream -> path t layer instrument stream date))
  in
  Deferred.List.filter ~how:`Sequential candidates ~f:Sys.file_exists_exn
;;
