(** {!Exchange_core.Size} with a stable binary encoding: the raw [int] count of 10^-8
    units. *)

open! Core

include module type of struct
  include Exchange_core.Size
end

include Binable.S with type t := t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]

    include Quickcheckable.S with type t := t
  end
end
