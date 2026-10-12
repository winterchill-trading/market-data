open! Core
module Md_stream = Stream
open! Async
module C = Parquet.Schema.Column

module Row = struct
  type t =
    { date : Date.t
    ; instrument : Instrument.t
    ; streams : Md_stream.t list
    ; info : Instrument_info.t option
    }
  [@@deriving sexp_of, compare, equal]
end

let kind_name : Instrument_info.Kind.t -> string = function
  | Spot -> "spot"
  | Perp -> "perp"
  | Future -> "future"
  | Option -> "option"
;;

let size_unit_name : Instrument_info.Size_unit.t -> string = function
  | Base -> "base"
  | Quote -> "quote"
  | Contracts _ -> "contracts"
;;

let info_string f (r : Row.t) = Option.value_map r.info ~default:"" ~f
let info_float f (r : Row.t) = Option.value_map r.info ~default:Float.nan ~f

let decimal name f =
  C.decimal
    ~precision:Parquet_schemas.decimal_precision
    ~scale:Parquet_schemas.decimal_scale
    name
    f
;;

let schema =
  Parquet.Schema.create
    [ C.utf8 "date" (fun (r : Row.t) -> Date.to_string r.date)
    ; C.utf8 "venue" (fun (r : Row.t) -> Venue.to_string (Instrument.venue r.instrument))
    ; C.utf8 "symbol" (fun (r : Row.t) ->
        Symbol.to_string (Instrument.symbol r.instrument))
    ; C.utf8 "streams" (fun (r : Row.t) ->
        String.concat ~sep:"," (List.map r.streams ~f:Md_stream.to_string))
    ; C.bool "in_catalogue" (fun (r : Row.t) -> Option.is_some r.info)
    ; C.utf8 "kind" (info_string (fun i -> kind_name i.kind))
    ; C.utf8 "base" (info_string (fun i -> i.base))
    ; C.utf8 "quote" (info_string (fun i -> i.quote))
    ; C.utf8 "size_unit" (info_string (fun i -> size_unit_name i.size_unit))
    ; C.float
        "units_per_contract"
        (info_float (fun i ->
           Option.value (Instrument_info.units_per_contract i) ~default:Float.nan))
    ; C.float "units_per_price" (info_float (fun i -> i.units_per_price))
    ; C.int64 "funding_interval_s" (fun (r : Row.t) ->
        match Option.bind r.info ~f:(fun i -> i.funding_interval) with
        | None -> 0
        | Some span -> Float.iround_nearest_exn (Time_ns.Span.to_sec span))
    ; decimal "tick" (fun (r : Row.t) ->
        Option.value_map r.info ~default:0 ~f:(fun i -> Price.to_units i.tick))
    ; decimal "lot" (fun (r : Row.t) ->
        Option.value_map r.info ~default:0 ~f:(fun i -> Size.to_units i.lot))
    ]
;;

let table_dir ~dir = dir ^/ "instruments"
let path ~dir date = table_dir ~dir ^/ Date.to_string date ^ ".parquet"
let glob ~dir = table_dir ~dir ^/ "*.parquet"

let rows ?catalogue ~dir date =
  let store = Store.create dir in
  let%bind instruments = Store.instruments store in
  let%map rows =
    Deferred.List.filter_map instruments ~how:`Sequential ~f:(fun instrument ->
      let%map streams =
        Deferred.List.filter Md_stream.all ~how:`Sequential ~f:(fun stream ->
          Sys.file_exists_exn (Store.path store Norm instrument stream date))
      in
      match streams with
      | [] -> None
      | streams ->
        Some
          { Row.date
          ; instrument
          ; streams
          ; info = Instrument_info.lookup ?catalogue instrument
          })
  in
  List.sort rows ~compare:Row.compare
;;

let write ?compression ?catalogue ~dir date =
  match%bind rows ?catalogue ~dir date with
  | [] -> return 0
  | rows ->
    let%bind file =
      Parquet_file.create ?compression schema ~row_group_rows:65_536 (path ~dir date)
    in
    let%bind () = Parquet_file.add file rows in
    let n = Parquet_file.num_rows file in
    let%map () = Parquet_file.close file in
    n
;;
