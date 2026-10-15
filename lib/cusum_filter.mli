(** Symmetric CUSUM filter: an event each time the cumulative log return since the last
    event in one direction passes a threshold [h].

    With [r = ln (p_k / p_(k-1))], [s+ = max 0 (s+ + r)] and [s- = min 0 (s- + r)]. When
    [s+ >= h] an [Up] event fires and [s+] restarts at 0; when [s- <= -h] a [Down] event
    fires and [s-] restarts at 0. A drifting price triggers repeatedly, a price that only
    oscillates within the band never does. The first price only seeds the filter. {!add}
    allocates only the event it returns. *)

open! Core

module Event : sig
  type t =
    { direction : Directional_change.Direction.t
    ; time : Time_ns.t
    ; price : Price.t
    ; sum : float (** [s+] or [s-] when it crossed *)
    }
  [@@deriving sexp, compare, equal]
end

type t

(** Raises unless [h] is positive and finite. *)
val create : threshold:float -> t

val threshold : t -> float
val add : t -> time:Time_ns.t -> Price.t -> Event.t or_null

(** [add] at the trade's [exch_ts] and price. *)
val add_trade : t -> Trade.t -> Event.t or_null

val of_prices : threshold:float -> (Time_ns.t * Price.t) list -> Event.t list
