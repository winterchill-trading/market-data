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

  (** Like [V1], but [exch_ts] is [None] when the venue sends no exchange timestamp
      (Hyperliquid funding), instead of a copy of [recv_ts]. *)
  module V2 : sig
    type t =
      { instrument : Instrument.Stable.V1.t
      ; exch_ts : Time_ns.Stable.V1.t option
      ; recv_ts : Time_ns.Stable.V1.t
      ; rate : float
      ; next_funding_time : Time_ns.Stable.V1.t
      ; mark_price : Price.Stable.V1.t
      ; index_price : Price.Stable.V1.t
      }
    [@@deriving bin_io, sexp, compare, equal, quickcheck]

    (** [exch_ts] becomes [Some exch_ts]. *)
    val of_v1 : V1.t -> t

    (** A missing [exch_ts] becomes [recv_ts], the convention of [V1]. *)
    val to_v1 : t -> V1.t
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

(** [None] when [exch_ts] equals [recv_ts]: producers without an exchange timestamp copy
    [recv_ts] into [exch_ts], and a real exchange timestamp never matches the receive time
    to the nanosecond. *)
val exch_ts_opt : t -> Time_ns.t option

(** [V2] with {!exch_ts_opt} as its [exch_ts]. [of_v2 (to_v2 t) = t] for every [t]. *)
val to_v2 : t -> Stable.V2.t

(** {!Stable.V2.to_v1}. *)
val of_v2 : Stable.V2.t -> t

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
