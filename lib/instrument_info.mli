(** Static facts about an instrument that its events do not carry: what kind of contract
    it is, what its sizes count, how often it funds, and its tick and lot.

    The built-in {!catalogue} is [data/instruments.sexp], embedded at build time. It is
    not exhaustive; {!load} reads a file in the same format to extend or replace it. *)

open! Core

module Kind : sig
  type t =
    | Spot
    | Perp
    | Future
    | Option
  [@@deriving sexp, compare, equal, enumerate]
end

module Size_unit : sig
  type t =
    | Base (** sizes count base tokens *)
    | Quote (** sizes count quote currency, e.g. Deribit inverse contracts in USD *)
    | Contracts of float (** sizes count contracts of this many base tokens *)
  [@@deriving sexp, compare, equal]
end

type t =
  { instrument : Instrument.t
  ; kind : Kind.t
  ; base : string (** the underlying asset, e.g. ["BTC"], ["PEPE"] *)
  ; quote : string (** the currency of prices, e.g. ["USDT"] *)
  ; size_unit : Size_unit.t
  ; units_per_price : float (** base tokens the quoted price is for, usually 1 *)
  ; funding_interval : Time_ns.Span.t option
  (** what one funding rate covers; [None] for instruments that do not fund *)
  ; tick : Price.t
  ; lot : Size.t
  }
[@@deriving compare, equal]

(** Flat records, as in [data/instruments.sexp]:
    [(venue Binance) (symbol BTCUSDT) (kind Perp) ...]; [units_per_price] defaults to 1
    and [funding_interval] may be omitted. *)
include Sexpable.S with type t := t

(** Base tokens per unit of size: [Some 1.] for [Base], [Some m] for [Contracts m], [None]
    for [Quote], where it depends on the price. *)
val units_per_contract : t -> float option

(** The built-in catalogue, sorted by instrument. *)
val catalogue : t list

(** Parses a list of entries. Fails on duplicate instruments. *)
val of_string : string -> t list Or_error.t

(** {!of_string} of a file. *)
val load : string -> t list Or_error.t

(** The entry of [instrument] in [catalogue] (default {!catalogue}). *)
val lookup : ?catalogue:t list -> Instrument.t -> t option
