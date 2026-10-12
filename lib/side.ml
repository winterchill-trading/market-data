open! Core

module Stable = struct
  module V1 = struct
    type t = Exchange_core.Side.t =
      | Buy
      | Sell
    [@@deriving bin_io, sexp, compare, equal, quickcheck, hash, enumerate]
  end
end

include Exchange_core.Side
include (Stable.V1 : Binable.S with type t := t)
