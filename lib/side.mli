(** {!Exchange_core.Side} with a stable binary encoding. *)

open! Core

module Stable : sig
  module V1 : sig
    type t = Exchange_core.Side.t =
      | Buy
      | Sell
    [@@deriving bin_io, sexp, compare, equal, quickcheck, hash, enumerate]
  end
end

include module type of struct
  include Exchange_core.Side
end

include Binable.S with type t := t
