open! Core

module Stable = struct
  module V1 = struct
    type t =
      { venue : Venue.Stable.V1.t
      ; symbol : Symbol.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal, hash, fields]
  end
end

module T = struct
  type t = Stable.V1.t =
    { venue : Venue.t
    ; symbol : Symbol.t
    }
  [@@deriving bin_io, sexp, compare, equal, hash, fields]
end

include T
include Comparable.Make (T)
include Hashable.Make (T)

let create venue symbol = { venue; symbol = Symbol.of_string symbol }
let to_string { venue; symbol } = Venue.to_string venue ^ ":" ^ Symbol.to_string symbol

let of_string s =
  match String.lsplit2 s ~on:':' with
  | Some (venue, symbol) -> create (Venue.of_string venue) symbol
  | None -> raise_s [%message "Instrument.of_string: expected <venue>:<symbol>" s]
;;
