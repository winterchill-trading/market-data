open! Core

module Stable = struct
  module V1 = struct
    type t =
      | Hyperliquid
      | Binance
      | Bybit
      | Okx
      | Coinbase
      | Kraken
      | Deribit
      | Bitget
      | Nyse
      | Cboe
      | Cme
    [@@deriving bin_io, sexp, compare, equal, quickcheck, hash, enumerate]
  end
end

module T = struct
  type t = Stable.V1.t =
    | Hyperliquid
    | Binance
    | Bybit
    | Okx
    | Coinbase
    | Kraken
    | Deribit
    | Bitget
    | Nyse
    | Cboe
    | Cme
  [@@deriving bin_io, sexp, compare, equal, hash, enumerate]
end

include T
include Comparable.Make (T)
include Hashable.Make (T)

let to_string = function
  | Hyperliquid -> "hyperliquid"
  | Binance -> "binance"
  | Bybit -> "bybit"
  | Okx -> "okx"
  | Coinbase -> "coinbase"
  | Kraken -> "kraken"
  | Deribit -> "deribit"
  | Bitget -> "bitget"
  | Nyse -> "nyse"
  | Cboe -> "cboe"
  | Cme -> "cme"
;;

let of_string_opt s =
  List.find all ~f:(fun t -> String.equal (to_string t) (String.lowercase s))
;;

let of_string s =
  match of_string_opt s with
  | Some t -> t
  | None -> raise_s [%message "Venue.of_string: unknown venue" (s : string)]
;;
