open! Core
module C = Parquet.Schema.Column

let decimal_precision = 18
let decimal_scale = Price.decimals
let decimal name f = C.decimal ~precision:decimal_precision ~scale:decimal_scale name f
let price name f = decimal name (fun r -> Price.to_units (f r))
let size name f = decimal name (fun r -> Size.to_units (f r))

let header ~instrument ~exch_ts ~recv_ts =
  [ C.utf8 "venue" (fun r -> Venue.to_string (Instrument.venue (instrument r)))
  ; C.utf8 "symbol" (fun r -> Symbol.to_string (Instrument.symbol (instrument r)))
  ; C.timestamp_ns "exch_ts" exch_ts
  ; C.timestamp_ns "recv_ts" recv_ts
  ]
;;

let side_name : Side.t -> string = function
  | Buy -> "buy"
  | Sell -> "sell"
;;

let trade =
  Parquet.Schema.create
    (header ~instrument:Trade.instrument ~exch_ts:Trade.exch_ts ~recv_ts:Trade.recv_ts
     @ [ price "price" Trade.price
       ; size "size" Trade.size
       ; C.utf8 "side" (fun (t : Trade.t) -> side_name t.side)
       ; C.utf8 "trade_id" Trade.trade_id
       ])
;;

let bbo =
  Parquet.Schema.create
    (header ~instrument:Bbo.instrument ~exch_ts:Bbo.exch_ts ~recv_ts:Bbo.recv_ts
     @ [ price "bid_price" Bbo.bid_price
       ; size "bid_size" Bbo.bid_size
       ; price "ask_price" Bbo.ask_price
       ; size "ask_size" Bbo.ask_size
       ])
;;

module L2_row = struct
  type t =
    { instrument : Instrument.t
    ; exch_ts : Time_ns.t
    ; recv_ts : Time_ns.t
    ; seq : int
    ; is_snapshot : bool
    ; side : Side.t
    ; level : int
    ; price : Price.t
    ; size : Size.t
    }
  [@@deriving sexp_of, compare, equal, fields ~getters]

  let of_update ~seq (u : L2_update.t) =
    let is_snapshot =
      match u.kind with
      | Snapshot -> true
      | Delta -> false
    in
    let rows side levels =
      List.mapi levels ~f:(fun level (l : L2_update.Level.t) ->
        { instrument = u.instrument
        ; exch_ts = u.exch_ts
        ; recv_ts = u.recv_ts
        ; seq
        ; is_snapshot
        ; side
        ; level
        ; price = l.price
        ; size = l.size
        })
    in
    rows Buy u.bids @ rows Sell u.asks
  ;;
end

let l2 =
  Parquet.Schema.create
    (header ~instrument:L2_row.instrument ~exch_ts:L2_row.exch_ts ~recv_ts:L2_row.recv_ts
     @ [ C.int64 "seq" L2_row.seq
       ; C.bool "is_snapshot" L2_row.is_snapshot
       ; C.utf8 "side" (fun (r : L2_row.t) ->
           match r.side with
           | Buy -> "bid"
           | Sell -> "ask")
       ; C.int32 "level" L2_row.level
       ; price "price" L2_row.price
       ; size "size" L2_row.size
       ])
;;

let funding =
  Parquet.Schema.create
    (header
       ~instrument:Funding.instrument
       ~exch_ts:Funding.exch_ts
       ~recv_ts:Funding.recv_ts
     @ [ C.float "rate" Funding.rate
       ; C.timestamp_ns "next_funding_time" Funding.next_funding_time
       ; price "mark_price" Funding.mark_price
       ; price "index_price" Funding.index_price
       ])
;;

let candle =
  Parquet.Schema.create
    [ C.utf8 "venue" (fun (c : Candle.t) ->
        Venue.to_string (Instrument.venue c.instrument))
    ; C.utf8 "symbol" (fun (c : Candle.t) ->
        Symbol.to_string (Instrument.symbol c.instrument))
    ; C.int64 "interval_ns" (fun (c : Candle.t) -> Time_ns.Span.to_int_ns c.interval)
    ; C.timestamp_ns "open_time" Candle.open_time
    ; price "open" Candle.open_
    ; price "high" Candle.high
    ; price "low" Candle.low
    ; price "close" Candle.close
    ; size "volume" Candle.volume
    ; C.int64 "trade_count" Candle.trade_count
    ]
;;
