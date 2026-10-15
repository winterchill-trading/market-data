(** Directional-change event clock: samples a price path at the points where it reverses
    by a fixed fraction [theta], instead of at fixed times.

    An upward directional change is confirmed when the price rises to [low * (1 + theta)],
    [low] being the lowest price since the last downward confirmation; a downward one when
    it falls to [high * (1 - theta)]. Each confirmation ends the previous trend at its
    extreme (the turning point) and starts a new one. The move from the previous
    confirmation price to that extreme, in the trend's direction, is the overshoot.

    Before the first event no trend is known: the clock tracks both the high and the low
    since the first price, and the first reversal of [theta] from either sets the trend.
    Events then alternate in direction. {!add} allocates only the event it returns. *)

open! Core

module Direction : sig
  type t =
    | Up
    | Down
  [@@deriving sexp, compare, equal, enumerate]
end

module Event : sig
  type t =
    { direction : Direction.t (** of the trend this event confirms *)
    ; extreme_ts : Time_ns.t
    (** the turning point: the extreme of the trend that ended, where this one starts *)
    ; extreme_price : Price.t
    ; confirm_ts : Time_ns.t (** the price that confirmed the reversal *)
    ; confirm_price : Price.t
    ; overshoot : float option
    (** of the trend that ended: [|extreme - previous confirm| / previous confirm], never
        negative; [None] for the first event, which has no previous confirmation *)
    }
  [@@deriving sexp, compare, equal]
end

type t

(** Raises unless [0 < theta < 1]. *)
val create : theta:float -> t

val theta : t -> float

(** Feeds one price; returns the event it confirmed, if any. *)
val add : t -> time:Time_ns.t -> Price.t -> Event.t or_null

(** [add] at the trade's [exch_ts] and price. *)
val add_trade : t -> Trade.t -> Event.t or_null

(** The current trend, [None] before the first event. *)
val trend : t -> Direction.t option

(** Every event of a price path. *)
val of_prices : theta:float -> (Time_ns.t * Price.t) list -> Event.t list
