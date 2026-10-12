(** Folds trades into {!Candle.t}s of a fixed interval.

    Candles are aligned to multiples of the interval since the Unix epoch and bucketed by
    the trade's [exch_ts]. An interval with no trades still produces a candle: open, high,
    low and close carry the previous close, volume and trade count are zero. A trade older
    than the current candle (out of order by less than a candle) is counted in the current
    candle. *)

open! Core

type t

(** [interval] must be between 1s and 1d and divide a day evenly. *)
val create : Instrument.t -> interval:Time_ns.Span.t -> t

val interval : t -> Time_ns.Span.t

(** Adds a trade; returns the candles it completed, oldest first (including empty ones for
    skipped intervals). *)
val add : t -> Trade.t -> Candle.t list

(** The candle in progress, if any trade was seen. *)
val current : t -> Candle.t option

(** All candles of a trade sequence, the last one possibly partial. *)
val of_trades : Instrument.t -> interval:Time_ns.Span.t -> Trade.t list -> Candle.t list

(** Start of the candle containing [time]. *)
val align : Time_ns.t -> interval:Time_ns.Span.t -> Time_ns.t
