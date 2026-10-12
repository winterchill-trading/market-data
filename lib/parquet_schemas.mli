(** Parquet schemas of the normalized types, one row per value.

    Every table starts with [venue] and [symbol] (strings), then [exch_ts] and [recv_ts]
    as [TIMESTAMP_NS]. Prices and sizes are [DECIMAL(18, 8)]: the raw fixed-decimal units
    with {!Price.decimals} fractional digits, so values are exact. Precision 18 covers
    magnitudes below 10^10; larger values would not fit the declared precision. *)

open! Core

(** Precision of price and size columns (18, the most an [INT64] decimal holds). *)
val decimal_precision : int

(** Scale of price and size columns, {!Price.decimals}. *)
val decimal_scale : int

(** [price], [size], [side] (["buy"] or ["sell"], the taker side), [trade_id]. *)
val trade : Trade.t Parquet.Schema.t

(** [bid_price], [bid_size], [ask_price], [ask_size]. *)
val bbo : Bbo.t Parquet.Schema.t

(** An {!L2_update.t} flattened to one row per price level. *)
module L2_row : sig
  type t =
    { instrument : Instrument.t
    ; exch_ts : Time_ns.t
    ; recv_ts : Time_ns.t
    ; seq : int (** number of the update within its file; all its levels share it *)
    ; is_snapshot : bool
    ; side : Side.t (** [Buy] for bids, [Sell] for asks *)
    ; level : int (** position within its side of the update, from 0 *)
    ; price : Price.t
    ; size : Size.t (** zero removes the level in a delta *)
    }
  [@@deriving sexp_of, compare, equal]

  (** Bids first, then asks, each in update order. An update with no levels yields no
      rows. *)
  val of_update : seq:int -> L2_update.t -> t list
end

(** [seq], [is_snapshot], [side] (["bid"] or ["ask"]), [level], [price], [size]. *)
val l2 : L2_row.t Parquet.Schema.t

(** [rate] (double), [next_funding_time], [mark_price], [index_price]. *)
val funding : Funding.t Parquet.Schema.t

(** [venue], [symbol], [interval_ns], [open_time], [open], [high], [low], [close],
    [volume], [trade_count]; no [exch_ts]/[recv_ts]. *)
val candle : Candle.t Parquet.Schema.t
