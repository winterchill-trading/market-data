(** Parquet schemas of the derived feature tables, written by {!Features} next to the
    day-close tables:

    {v
    <root>/<venue>/<symbol>/parquet/bars/<YYYY-MM-DD>.parquet
    <root>/<venue>/<symbol>/parquet/toxicity/<YYYY-MM-DD>.parquet
    v}

    They follow {!Parquet_schemas}: [venue] and [symbol] first, [TIMESTAMP_NS] times,
    prices and sizes as [DECIMAL(18, 8)]. Computed quantities (values, VPIN, z-scores) are
    [DOUBLE]; undefined ones are null. These tables are not {!Parquet_kind}s: [day-close],
    [views] and [catalog] leave them alone. *)

open! Core

(** A bar and the bars it belongs to. *)
module Bar_row : sig
  type t =
    { bar_type : string (** {!Bars.Spec.to_string}, e.g. ["tick-1000"] *)
    ; complete : bool (** [false] for the day's last, partial bar *)
    ; bar : Bars.Bar.t
    }
  [@@deriving sexp_of]
end

(** [venue], [symbol], [bar_type], [complete], [first_ts], [last_ts], [open], [high],
    [low], [close], [volume], [buy_volume], [notional] (double), [trade_count],
    [threshold] (double). *)
val bars : Bar_row.t Parquet.Schema.t

(** [venue], [symbol], [bucket], [start_ts], [end_ts], [buy_volume], [sell_volume],
    [imbalance] (doubles), [dominant] (["buy"], ["sell"] or null), [vpin] (double),
    [buckets], [zscore] and [cdf] (doubles, null when undefined). *)
val toxicity : Toxicity.Event.t Parquet.Schema.t
