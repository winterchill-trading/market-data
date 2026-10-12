(** Best bid and offer (top of book). *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t
      ; recv_ts : Time_ns.Stable.V1.t
      ; bid_price : Price.Stable.V1.t
      ; bid_size : Size.Stable.V1.t
      ; ask_price : Price.Stable.V1.t
      ; ask_size : Size.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal, fields]
  end
end

type t = Stable.V1.t =
  { instrument : Instrument.t
  ; exch_ts : Time_ns.t
  ; recv_ts : Time_ns.t
  ; bid_price : Price.t
  ; bid_size : Size.t
  ; ask_price : Price.t
  ; ask_size : Size.t
  }
[@@deriving bin_io, sexp, compare, equal, fields]

(** [(bid + ask) / 2], truncated to the price precision. *)
val mid : t -> Price.t

(** [ask - bid]. *)
val spread : t -> Price.t
