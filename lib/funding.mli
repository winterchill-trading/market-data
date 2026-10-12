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
    [@@deriving bin_io, sexp, compare, equal, quickcheck, fields]
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

(** [rate] scaled to an 8 hour interval, for comparing venues that fund at different
    intervals: [rate *. 8h /. funding_interval]. The interval defaults to the instrument's
    {!Instrument_info.funding_interval} in [catalogue] (default
    {!Instrument_info.catalogue}); [None] when the instrument is unknown or has no
    interval. *)
val normalized_8h
  :  ?funding_interval:Time_ns.Span.t
  -> ?catalogue:Instrument_info.t list
  -> t
  -> float option
