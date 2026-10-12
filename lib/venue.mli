(** Trading venues with recorded market data. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      | Hyperliquid
      | Binance
      | Bybit
    [@@deriving bin_io, sexp, compare, equal, hash, enumerate]
  end
end

type t = Stable.V1.t =
  | Hyperliquid
  | Binance
  | Bybit
[@@deriving bin_io, sexp, compare, equal, hash, enumerate]

include Comparable.S with type t := t
include Hashable.S with type t := t

(** Stable lowercase name used in file paths: ["hyperliquid"], ["binance"], ["bybit"]. *)
val to_string : t -> string

(** Inverse of {!to_string}; case-insensitive. Raises on unknown names. *)
val of_string : string -> t

val of_string_opt : string -> t option
