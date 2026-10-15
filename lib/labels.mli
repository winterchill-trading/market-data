(** Triple-barrier labels for supervised learning on a price series.

    For an event entered at observation [i] (price [p], time [t]) with width [w] (a
    relative move, typically the recent volatility of returns from {!ewma_volatility}),
    three barriers are set:

    - upper at [p * (1 + profit_take * w)] and lower at [p * (1 - stop_loss * w)] for a
      long or unsided event; a short event has its profit barrier below
      ([p * (1 - profit_take * w)]) and its stop above ([p * (1 + stop_loss * w)]);
    - vertical at [t + vertical].

    The label comes from the first barrier the path touches after [i] (a price at or past
    a horizontal barrier, or the last observation at or before the vertical time). The
    series ending first gives [End_of_data] at its last observation. A missing multiplier
    or holding period removes that barrier.

    Without a side the label is [+1] at the upper barrier, [-1] at the lower one, and the
    sign of the return at the vertical barrier or the end of data. With a side (a primary
    model's bet) the label is a meta-label: [1] if the bet's return is positive, else [0],
    to train a second model deciding whether to act on the first. *)

open! Core

module Barriers : sig
  type t =
    { profit_take : float option (** multiple of the event width *)
    ; stop_loss : float option (** multiple of the event width *)
    ; vertical : Time_ns.Span.t option (** holding period *)
    }
  [@@deriving sexp, compare, equal]
end

module Event : sig
  type t =
    { index : int (** the entry, an index into the series *)
    ; width : float (** relative barrier unit, positive *)
    ; side : Side.t option (** the primary model's bet, for meta-labels *)
    }
  [@@deriving sexp, compare, equal]
end

module Barrier : sig
  type t =
    | Profit_take
    | Stop_loss
    | Vertical
    | End_of_data
  [@@deriving sexp, compare, equal, enumerate]
end

module Label : sig
  type t =
    { index : int
    ; exit_index : int
    ; entry_time : Time_ns.t
    ; exit_time : Time_ns.t
    ; entry_price : float
    ; exit_price : float
    ; barrier : Barrier.t
    ; return : float
    (** [exit_price / entry_price - 1], negated for a short event: the bet's return *)
    ; label : int (** [-1], [0] or [1]; [0] or [1] for a meta-label *)
    }
  [@@deriving sexp, compare, equal]
end

(** Labels of [events], in their order. [times] (non-decreasing) and [prices] (positive)
    have equal lengths. Raises on an event index outside the series or a non-positive
    width when a horizontal barrier is set. An event at the last observation ends at once
    with [End_of_data] and a zero return. Each event scans forward from its entry, so
    labelling is O(events * horizon). *)
val label
  :  times:Time_ns.t array
  -> prices:float array
  -> Barriers.t
  -> Event.t list
  -> Label.t list

(** Exponentially weighted standard deviation of simple returns [p_k / p_(k-1) - 1] with
    [alpha = 2 / (span + 1)], seeded by the first return; [nan] at index 0. *)
val ewma_volatility : prices:float array -> span:int -> float array
