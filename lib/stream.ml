open! Core

module Stable = struct
  module V1 = struct
    type t =
      | Trades
      | Bbo
      | L2
      | Funding
      | Private
    [@@deriving bin_io, sexp, compare, equal, hash, enumerate]
  end
end

module T = struct
  type t = Stable.V1.t =
    | Trades
    | Bbo
    | L2
    | Funding
    | Private
  [@@deriving bin_io, sexp, compare, equal, hash, enumerate]
end

include T
include Comparable.Make (T)
include Hashable.Make (T)

let to_string = function
  | Trades -> "trades"
  | Bbo -> "bbo"
  | L2 -> "l2"
  | Funding -> "funding"
  | Private -> "private"
;;

let of_string_opt s =
  List.find all ~f:(fun t -> String.equal (to_string t) (String.lowercase s))
;;

let of_string s =
  match of_string_opt s with
  | Some t -> t
  | None -> raise_s [%message "Stream.of_string: unknown stream" (s : string)]
;;
