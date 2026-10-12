(** Funding, mark and index of a perpetual contract. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t
      ; recv_ts : Time_ns.Stable.V1.t
      ; rate : float (** per funding interval, e.g. [0.0001] for 1 bp *)
      ; next_funding_time : Time_ns.Stable.V1.t
      ; mark_price : Price.Stable.V1.t
      ; index_price : Price.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal, fields]
  end
end

type t = Stable.V1.t =
  { instrument : Instrument.t
  ; exch_ts : Time_ns.t
  ; recv_ts : Time_ns.t
  ; rate : float
  ; next_funding_time : Time_ns.t
  ; mark_price : Price.t
  ; index_price : Price.t
  }
[@@deriving bin_io, sexp, compare, equal, fields]
