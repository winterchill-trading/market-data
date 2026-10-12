open! Core

type t =
  | Trades
  | Bbo
  | L2
  | Funding
  | Candles
[@@deriving sexp, compare, equal, hash, enumerate]

let to_string = function
  | Trades -> "trades"
  | Bbo -> "bbo"
  | L2 -> "l2"
  | Funding -> "funding"
  | Candles -> "candles"
;;

let of_string s =
  match List.find all ~f:(fun t -> String.Caseless.equal (to_string t) s) with
  | Some t -> t
  | None -> raise_s [%message "Parquet_kind.of_string: unknown kind" (s : string)]
;;

let of_stream : Stream.t -> t option = function
  | Trades -> Some Trades
  | Bbo -> Some Bbo
  | L2 -> Some L2
  | Funding -> Some Funding
  | Private -> None
;;

let kind_dir ~dir instrument t =
  Store.instrument_dir (Store.create dir) instrument ^/ "parquet" ^/ to_string t
;;

let path ~dir instrument t date =
  kind_dir ~dir instrument t ^/ Date.to_string date ^ ".parquet"
;;
