(** Order-flow toxicity: the volume-synchronised probability of informed trading (VPIN)
    over equal-volume buckets, with a rolling z-score and percentile of the result.

    Trades fill buckets of [bucket_volume] (base units) in arrival order. Each trade's
    size is split into buy and sell volume by the [classification]:

    - [Aggressor]: the venue's taker side. Exact when the venue reports it, as the crypto
      venues recorded here do; the default.
    - [Tick_rule]: buy on an up-tick, sell on a down-tick; a zero tick repeats the
      previous trade's split, and the first trade is split evenly.
    - [Bulk { interval; span }]: bulk volume classification. Trades are summed into time
      bars of [interval] (by [exch_ts]); a bar's volume is bought in the share
      [Phi (dP / sigma)], with [dP] the change of the bar's last price from the previous
      bar's, [Phi] the standard normal distribution function and [sigma] the exponentially
      weighted standard deviation of [dP] over the previous bars (span [span]). Without a
      previous bar or a [sigma] yet, the share is one half. A bar is classified when the
      first trade of a later bar arrives, or at {!flush}.

    Volume that overfills a bucket spills into the next ones with the same split, so one
    trade (or bar) may fill several buckets. For each filled bucket with buy and sell
    volume [B] and [S] ([B + S = V]):

    - order imbalance [|B - S| / V];
    - [vpin], the mean order imbalance over the last [window] buckets (fewer at the start:
      [buckets] says how many);
    - [zscore], [(vpin - m) / s] with [m] and [s] the mean and standard deviation of the
      previous [zscore_window] VPIN values ([None] with fewer than two or [s <= 1e-9]),
      and [cdf], the share of those previous values below [vpin], equal ones counting half
      ([None] with none).

    VPIN warns of adverse selection and of volatility to come; it does not tell the
    direction. The signed [imbalance] and [dominant] side of each bucket say which side
    the flow came from. {!add} allocates nothing for a trade that fills no bucket (with
    [Aggressor] and [Tick_rule]). *)

open! Core

module Classification : sig
  type t =
    | Aggressor
    | Tick_rule
    | Bulk of
        { interval : Time_ns.Span.t
        ; span : int
        }
  [@@deriving sexp, compare, equal]

  (** ["aggressor"], ["tick-rule"], ["bulk-<interval>"]. *)
  val to_string : t -> string

  (** Inverse of [to_string]; [bulk-<interval>] with span 20 bars. *)
  val of_string : string -> t Or_error.t
end

module Config : sig
  type t =
    { bucket_volume : Size.t
    ; window : int (** buckets in the VPIN mean *)
    ; zscore_window : int (** previous VPIN values for the z-score and percentile *)
    ; classification : Classification.t
    }
  [@@deriving sexp, compare, equal]

  (** A window of 50 buckets, 250 previous values for the z-score, [Aggressor]. *)
  val default : bucket_volume:Size.t -> t

  val validate : t -> t Or_error.t
end

(** One filled bucket. *)
module Event : sig
  type t =
    { instrument : Instrument.t
    ; bucket : int (** from 0 *)
    ; start_ts : Time_ns.t (** [exch_ts] of the first volume in the bucket *)
    ; end_ts : Time_ns.t (** [exch_ts] of the trade (or bar) that filled it *)
    ; buy_volume : float
    ; sell_volume : float
    ; imbalance : float (** [(B - S) / V], in [-1, 1] *)
    ; dominant : Side.t option (** the side with more volume; [None] when equal *)
    ; vpin : float
    ; buckets : int (** buckets in the [vpin] mean *)
    ; zscore : float option
    ; cdf : float option
    }
  [@@deriving sexp, compare, equal]
end

type t

(** Raises if [Config.validate] fails. *)
val create : Instrument.t -> Config.t -> t

val instrument : t -> Instrument.t
val config : t -> Config.t

(** Adds a trade; returns the buckets it filled, oldest first. *)
val add : t -> Trade.t -> Event.t list

(** With [Bulk], classifies the bar in progress and returns the buckets it filled;
    otherwise (and with no bar in progress) nothing. *)
val flush : t -> Event.t list

(** The last bucket's VPIN; [nan] before the first bucket. *)
val vpin : t -> float

(** Volume in the bucket in progress. *)
val pending_volume : t -> float

(** Every event of a trade sequence, {!flush} included. *)
val of_trades : Instrument.t -> Config.t -> Trade.t list -> Event.t list
