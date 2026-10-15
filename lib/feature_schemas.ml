open! Core
module C = Parquet.Schema.Column

module Bar_row = struct
  type t =
    { bar_type : string
    ; complete : bool
    ; bar : Bars.Bar.t
    }
  [@@deriving sexp_of]
end

let decimal name f =
  C.decimal
    ~precision:Parquet_schemas.decimal_precision
    ~scale:Parquet_schemas.decimal_scale
    name
    f
;;

let price name f = decimal name (fun r -> Price.to_units (f r))
let size name f = decimal name (fun r -> Size.to_units (f r))

let bars =
  let bar f (r : Bar_row.t) = f r.bar in
  Parquet.Schema.create
    [ C.dictionary
        (C.utf8 "venue" (bar (fun b -> Venue.to_string (Instrument.venue b.instrument))))
    ; C.dictionary
        (C.utf8
           "symbol"
           (bar (fun b -> Symbol.to_string (Instrument.symbol b.instrument))))
    ; C.dictionary (C.utf8 "bar_type" (fun (r : Bar_row.t) -> r.bar_type))
    ; C.bool "complete" (fun (r : Bar_row.t) -> r.complete)
    ; C.timestamp_ns "first_ts" (bar Bars.Bar.first_ts)
    ; C.timestamp_ns "last_ts" (bar Bars.Bar.last_ts)
    ; price "open" (bar Bars.Bar.open_)
    ; price "high" (bar Bars.Bar.high)
    ; price "low" (bar Bars.Bar.low)
    ; price "close" (bar Bars.Bar.close)
    ; size "volume" (bar Bars.Bar.volume)
    ; size "buy_volume" (bar Bars.Bar.buy_volume)
    ; C.float "notional" (bar Bars.Bar.notional)
    ; C.int64 "trade_count" (bar Bars.Bar.trade_count)
    ; C.float "threshold" (bar Bars.Bar.threshold)
    ]
;;

let toxicity =
  let open Toxicity.Event in
  Parquet.Schema.create
    [ C.dictionary
        (C.utf8 "venue" (fun e -> Venue.to_string (Instrument.venue e.instrument)))
    ; C.dictionary
        (C.utf8 "symbol" (fun e -> Symbol.to_string (Instrument.symbol e.instrument)))
    ; C.int64 "bucket" (fun e -> e.bucket)
    ; C.timestamp_ns "start_ts" (fun e -> e.start_ts)
    ; C.timestamp_ns "end_ts" (fun e -> e.end_ts)
    ; C.float "buy_volume" (fun e -> e.buy_volume)
    ; C.float "sell_volume" (fun e -> e.sell_volume)
    ; C.float "imbalance" (fun e -> e.imbalance)
    ; C.optional C.utf8 "dominant" (fun e ->
        Option.map e.dominant ~f:(function
          | Side.Buy -> "buy"
          | Sell -> "sell"))
    ; C.float "vpin" (fun e -> e.vpin)
    ; C.int64 "buckets" (fun e -> e.buckets)
    ; C.optional C.float "zscore" (fun e -> e.zscore)
    ; C.optional C.float "cdf" (fun e -> e.cdf)
    ]
;;
