(** OHLCV bar over a fixed interval. *)

open! Core

module Stable : sig
  module V1 : sig
    type t =
      { instrument : Instrument.Stable.V1.t
      ; interval : Time_ns.Stable.Span.V2.t
      ; open_time : Time_ns.Stable.V1.t (** inclusive start, aligned to [interval] *)
      ; open_ : Price.Stable.V1.t
      ; high : Price.Stable.V1.t
      ; low : Price.Stable.V1.t
      ; close : Price.Stable.V1.t
      ; volume : Size.Stable.V1.t (** sum of trade sizes *)
      ; trade_count : int
      }
    [@@deriving bin_io, sexp, compare, equal, fields]
  end
end

type t = Stable.V1.t =
  { instrument : Instrument.t
  ; interval : Time_ns.Span.t
  ; open_time : Time_ns.t
  ; open_ : Price.t
  ; high : Price.t
  ; low : Price.t
  ; close : Price.t
  ; volume : Size.t
  ; trade_count : int
  }
[@@deriving bin_io, sexp, compare, equal, fields]

(** Exclusive end: [open_time + interval]. *)
val close_time : t -> Time_ns.t
