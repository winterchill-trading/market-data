(** A public trade print. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t (** venue timestamp *)
      ; recv_ts : Time_ns.Stable.V1.t (** local receive timestamp *)
      ; price : Price.Stable.V1.t
      ; size : Size.Stable.V1.t
      ; side : Side.Stable.V1.t (** taker (aggressor) side *)
      ; trade_id : string (** venue trade id; opaque *)
      }
    [@@deriving bin_io, sexp, compare, equal, fields]
  end
end

type t = Stable.V1.t =
  { instrument : Instrument.t
  ; exch_ts : Time_ns.t
  ; recv_ts : Time_ns.t
  ; price : Price.t
  ; size : Size.t
  ; side : Side.t
  ; trade_id : string
  }
[@@deriving bin_io, sexp, compare, equal, fields]
