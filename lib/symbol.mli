(** {!Exchange_core.Symbol} with a stable binary encoding (as a string). *)

open! Core

include module type of struct
  include Exchange_core.Symbol
end

include Binable.S with type t := t

module Stable : sig
  module V1 : sig
    type nonrec t = t [@@deriving bin_io, sexp, compare, equal, hash]
  end
end
