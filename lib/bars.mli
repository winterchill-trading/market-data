(** Information-driven bars: trades sampled by activity instead of by the clock.

    A bar closes when what it has accumulated reaches a threshold:

    - [Tick n]: [n] trades.
    - [Volume s]: traded size of at least [s] (base units).
    - [Dollar x]: traded value [price * size] of at least [x] (quote units).
    - [Imbalance (m, a)]: the signed flow [theta = sum b_i * v_i] has
      [|theta| >= E[T] * |E[b v]|], with [b_i] the taker side ([+1] buy, [-1] sell), [v_i]
      the trade's measure ([1], size or value), [E[T]] the expected trades per bar and
      [E[b v]] the expected signed measure per trade, both exponentially weighted over the
      bars closed so far.
    - [Run (m, a)]: the larger one-sided sum [max (sum_buy v_i, sum_sell v_i)] reaches
      [E[T] * max (E[v+], E[v-])], with [E[v+]] and [E[v-]] the expected buy and sell
      measure per trade.

    The adaptive kinds start with a warm-up bar of [warmup_ticks] trades, which seeds the
    expectations. [E[T]] is kept between [min_ticks] and [max_ticks] and a bar never
    closes before [min_ticks] trades: without those bounds the threshold of imbalance bars
    is known to collapse to one trade per bar, or to run away, on balanced flow.

    A trade is never split: the trade that crosses the threshold closes its bar whole, so
    the bars of a stream (with the partial bar from {!current}) hold every trade exactly
    once and their volumes and counts add up to the input's. Bars use the trades'
    [exch_ts] and arrival order. {!add} allocates only the bar it returns. *)

open! Core

(** What an adaptive bar measures per trade. *)
module Measure : sig
  type t =
    | Ticks (** 1 per trade *)
    | Volume (** size *)
    | Dollar (** price times size *)
  [@@deriving sexp, compare, equal, enumerate]

  (** ["tick"], ["volume"], ["dollar"]. *)
  val to_string : t -> string
end

(** Expectation tracking of the adaptive bars. *)
module Adaptive : sig
  type t =
    { warmup_ticks : int (** trades in the first bar, which seeds the expectations *)
    ; span : int (** span, in bars, of the exponentially weighted expectations *)
    ; min_ticks : int (** least trades per bar, and floor of [E[T]] *)
    ; max_ticks : int (** ceiling of [E[T]] *)
    }
  [@@deriving sexp, compare, equal]

  (** Span 20 bars, [min_ticks] a tenth of [warmup_ticks] (at least 1), [max_ticks] ten
      times [warmup_ticks]. *)
  val default : warmup_ticks:int -> t
end

module Spec : sig
  type t =
    | Tick of int
    | Volume of Size.t
    | Dollar of float
    | Imbalance of Measure.t * Adaptive.t
    | Run of Measure.t * Adaptive.t
  [@@deriving sexp, compare, equal]

  (** Positive thresholds; for the adaptive kinds
      [1 <= min_ticks <= warmup_ticks <= max_ticks] and a positive span. *)
  val validate : t -> t Or_error.t

  (** A short label, also the [bar_type] column of the bars table: ["tick-500"],
      ["volume-2.5"], ["dollar-1000000"], ["volume-imbalance-100"], ["tick-run-100"] (the
      adaptive ones name their warm-up length). *)
  val to_string : t -> string

  (** Parses [tick:N], [volume:SIZE], [dollar:X], and [<measure>-imbalance:N] or
      [<measure>-run:N] with [N] warm-up trades and {!Adaptive.default} otherwise. *)
  val of_string : string -> t Or_error.t
end

(** One closed (or, from {!current}, partial) bar. *)
module Bar : sig
  module Stable : sig
    module V1 : sig
      type t =
        { instrument : Instrument.Stable.V1.t
        ; first_ts : Time_ns.Stable.V1.t (** [exch_ts] of the first trade *)
        ; last_ts : Time_ns.Stable.V1.t (** [exch_ts] of the last trade *)
        ; open_ : Price.Stable.V1.t
        ; high : Price.Stable.V1.t
        ; low : Price.Stable.V1.t
        ; close : Price.Stable.V1.t
        ; volume : Size.Stable.V1.t (** sum of trade sizes *)
        ; buy_volume : Size.Stable.V1.t (** size of the trades whose taker bought *)
        ; notional : float (** sum of [price * size] *)
        ; trade_count : int
        ; threshold : float
        (** the threshold the bar was closed against, in its measure's units (trades, size
            or value); for imbalance and run bars the adaptive one at closing time, and
            for their warm-up bar its trade count *)
        }
      [@@deriving bin_io, sexp, compare, equal, quickcheck]
    end
  end

  type t = Stable.V1.t =
    { instrument : Instrument.t
    ; first_ts : Time_ns.t
    ; last_ts : Time_ns.t
    ; open_ : Price.t
    ; high : Price.t
    ; low : Price.t
    ; close : Price.t
    ; volume : Size.t
    ; buy_volume : Size.t
    ; notional : float
    ; trade_count : int
    ; threshold : float
    }
  [@@deriving bin_io, sexp, compare, equal, fields]
end

type t

(** Raises if [Spec.validate] fails. *)
val create : Instrument.t -> Spec.t -> t

val instrument : t -> Instrument.t
val spec : t -> Spec.t

(** Adds a trade; returns the bar it closed, if any. *)
val add : t -> Trade.t -> Bar.t or_null

(** The bar in progress, if it has any trade. *)
val current : t -> Bar.t option

(** The threshold the bar in progress closes at ([E[T] * ...] for the adaptive kinds;
    [Float.infinity] during their warm-up, which closes on the trade count). *)
val threshold : t -> float

(** All bars of a trade sequence, the last one possibly partial. *)
val of_trades : Instrument.t -> Spec.t -> Trade.t list -> Bar.t list
