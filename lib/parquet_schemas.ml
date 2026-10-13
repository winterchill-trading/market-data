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

module Direct = struct
  module D = Parquet.Writer.Direct

  type 'a t = 'a Parquet.Writer.t -> 'a -> unit

  (* A [float] field is already boxed; unboxing it to call [add_float_u] is free and keeps
     the cross-module call from boxing it again. *)
  external unbox_float : float -> float# = "%unbox_float"

  let ns t = Time_ns.to_int_ns_since_epoch t

  type header =
    { venue : D.string_column
    ; symbol : D.string_column
    ; exch_ts : D.int_column
    ; recv_ts : D.int_column
    }

  let header w =
    { venue = D.string w "venue"
    ; symbol = D.string w "symbol"
    ; exch_ts = D.int w "exch_ts"
    ; recv_ts = D.int w "recv_ts"
    }
  ;;

  let add_header h instrument ~exch_ts ~recv_ts =
    D.add_string h.venue (Venue.to_string (Instrument.venue instrument));
    D.add_string h.symbol (Symbol.to_string (Instrument.symbol instrument));
    D.add_int h.exch_ts (ns exch_ts);
    D.add_int h.recv_ts (ns recv_ts)
  ;;

  let trade w =
    let h = header w
    and price = D.int w "price"
    and size = D.int w "size"
    and side = D.string w "side"
    and trade_id = D.string w "trade_id" in
    fun (t : Trade.t) ->
      add_header h t.instrument ~exch_ts:t.exch_ts ~recv_ts:t.recv_ts;
      D.add_int price (Price.to_units t.price);
      D.add_int size (Size.to_units t.size);
      D.add_string side (side_name t.side);
      D.add_string trade_id t.trade_id;
      D.end_row w
  ;;

  let bbo w =
    let h = header w
    and bid_price = D.int w "bid_price"
    and bid_size = D.int w "bid_size"
    and ask_price = D.int w "ask_price"
    and ask_size = D.int w "ask_size" in
    fun (b : Bbo.t) ->
      add_header h b.instrument ~exch_ts:b.exch_ts ~recv_ts:b.recv_ts;
      D.add_int bid_price (Price.to_units b.bid_price);
      D.add_int bid_size (Size.to_units b.bid_size);
      D.add_int ask_price (Price.to_units b.ask_price);
      D.add_int ask_size (Size.to_units b.ask_size);
      D.end_row w
  ;;

  type l2 =
    { h : header
    ; seq : D.int_column
    ; is_snapshot : D.bool_column
    ; side : D.string_column
    ; level : D.int_column
    ; price : D.int_column
    ; size : D.int_column
    }

  let l2_columns w =
    { h = header w
    ; seq = D.int w "seq"
    ; is_snapshot = D.bool w "is_snapshot"
    ; side = D.string w "side"
    ; level = D.int w "level"
    ; price = D.int w "price"
    ; size = D.int w "size"
    }
  ;;

  let l2_side_name : Side.t -> string = function
    | Buy -> "bid"
    | Sell -> "ask"
  ;;

  let add_l2 c w instrument ~exch_ts ~recv_ts ~seq ~is_snapshot ~side ~level ~price ~size =
    add_header c.h instrument ~exch_ts ~recv_ts;
    D.add_int c.seq seq;
    D.add_bool c.is_snapshot is_snapshot;
    D.add_string c.side (l2_side_name side);
    D.add_int c.level level;
    D.add_int c.price (Price.to_units price);
    D.add_int c.size (Size.to_units size);
    D.end_row w
  ;;

  let l2 w =
    let c = l2_columns w in
    fun (r : L2_row.t) ->
      add_l2
        c
        w
        r.instrument
        ~exch_ts:r.exch_ts
        ~recv_ts:r.recv_ts
        ~seq:r.seq
        ~is_snapshot:r.is_snapshot
        ~side:r.side
        ~level:r.level
        ~price:r.price
        ~size:r.size
  ;;

  (* Top level rather than a local function over the levels: a local closure capturing the
     update costs 24 words per update. *)
  let rec add_levels c w (u : L2_update.t) ~seq ~is_snapshot side level = function
    | [] -> ()
    | (l : L2_update.Level.t) :: rest ->
      add_l2
        c
        w
        u.instrument
        ~exch_ts:u.exch_ts
        ~recv_ts:u.recv_ts
        ~seq
        ~is_snapshot
        ~side
        ~level
        ~price:l.price
        ~size:l.size;
      add_levels c w u ~seq ~is_snapshot side (level + 1) rest
  ;;

  let l2_update w =
    let c = l2_columns w in
    fun ~seq (u : L2_update.t) ->
      let is_snapshot =
        match u.kind with
        | Snapshot -> true
        | Delta -> false
      in
      add_levels c w u ~seq ~is_snapshot Buy 0 u.bids;
      add_levels c w u ~seq ~is_snapshot Sell 0 u.asks
  ;;

  let funding w =
    let h = header w
    and rate = D.float w "rate"
    and next_funding_time = D.int w "next_funding_time"
    and mark_price = D.int w "mark_price"
    and index_price = D.int w "index_price" in
    fun (f : Funding.t) ->
      add_header h f.instrument ~exch_ts:f.exch_ts ~recv_ts:f.recv_ts;
      D.add_float_u rate (unbox_float f.rate);
      D.add_int next_funding_time (ns f.next_funding_time);
      D.add_int mark_price (Price.to_units f.mark_price);
      D.add_int index_price (Price.to_units f.index_price);
      D.end_row w
  ;;

  let candle w =
    let venue = D.string w "venue"
    and symbol = D.string w "symbol"
    and interval_ns = D.int w "interval_ns"
    and open_time = D.int w "open_time"
    and open_ = D.int w "open"
    and high = D.int w "high"
    and low = D.int w "low"
    and close = D.int w "close"
    and volume = D.int w "volume"
    and trade_count = D.int w "trade_count" in
    fun (c : Candle.t) ->
      D.add_string venue (Venue.to_string (Instrument.venue c.instrument));
      D.add_string symbol (Symbol.to_string (Instrument.symbol c.instrument));
      D.add_int interval_ns (Time_ns.Span.to_int_ns c.interval);
      D.add_int open_time (ns c.open_time);
      D.add_int open_ (Price.to_units c.open_);
      D.add_int high (Price.to_units c.high);
      D.add_int low (Price.to_units c.low);
      D.add_int close (Price.to_units c.close);
      D.add_int volume (Size.to_units c.volume);
      D.add_int trade_count c.trade_count;
      D.end_row w
  ;;
end
