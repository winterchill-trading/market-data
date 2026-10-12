(** A symbol on a venue, e.g. [binance:BTCUSDT]. The symbol is the venue's own name for
    the market. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      { venue : Venue.Stable.V1.t
      ; symbol : Symbol.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal, hash, fields]
  end
end

type t = Stable.V1.t =
  { venue : Venue.t
  ; symbol : Symbol.t
  }
[@@deriving bin_io, sexp, compare, equal, hash, fields]

include Comparable.S with type t := t
include Hashable.S with type t := t

val create : Venue.t -> string -> t

(** ["<venue>:<symbol>"], e.g. ["bybit:BTCUSDT"]. *)
val to_string : t -> string

(** Inverse of {!to_string}. Raises on a missing [':'] or an unknown venue. *)
val of_string : string -> t
