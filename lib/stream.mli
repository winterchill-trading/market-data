(** Kinds of market data streams recorded per instrument. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      | Trades
      | Bbo
      | L2
      | Funding
      | Private (** account streams: fills, orders, positions *)
    [@@deriving bin_io, sexp, compare, equal, hash, enumerate]
  end
end

type t = Stable.V1.t =
  | Trades
  | Bbo
  | L2
  | Funding
  | Private
[@@deriving bin_io, sexp, compare, equal, hash, enumerate]

include Comparable.S with type t := t
include Hashable.S with type t := t

(** Stable lowercase name used in file paths: ["trades"], ["bbo"], ["l2"], ["funding"],
    ["private"]. *)
val to_string : t -> string

(** Inverse of {!to_string}; case-insensitive. Raises on unknown names. *)
val of_string : string -> t

val of_string_opt : string -> t option
