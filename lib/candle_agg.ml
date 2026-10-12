open! Core

type t =
  { instrument : Instrument.t
  ; interval : Time_ns.Span.t
  ; mutable current : Candle.t option
  }

let interval t = t.interval
let current t = t.current

let create instrument ~interval =
  let ns = Time_ns.Span.to_int_ns interval in
  let day = Time_ns.Span.to_int_ns Time_ns.Span.day in
  if Time_ns.Span.( < ) interval Time_ns.Span.second
     || Time_ns.Span.( > ) interval Time_ns.Span.day
     || day % ns <> 0
  then
    raise_s
      [%message
        "Candle_agg.create: interval must be 1s..1d and divide a day"
          (interval : Time_ns.Span.t)];
  { instrument; interval; current = None }
;;

let align time ~interval =
  let ns = Time_ns.Span.to_int_ns interval in
  let t = Time_ns.to_int_ns_since_epoch time in
  Time_ns.of_int_ns_since_epoch (t - (t % ns))
;;

let empty t ~open_time ~(prev : Candle.t) : Candle.t =
  { instrument = t.instrument
  ; interval = t.interval
  ; open_time
  ; open_ = prev.close
  ; high = prev.close
  ; low = prev.close
  ; close = prev.close
  ; volume = Size.zero
  ; trade_count = 0
  }
;;

let start t ~open_time (trade : Trade.t) : Candle.t =
  { instrument = t.instrument
  ; interval = t.interval
  ; open_time
  ; open_ = trade.price
  ; high = trade.price
  ; low = trade.price
  ; close = trade.price
  ; volume = trade.size
  ; trade_count = 1
  }
;;

let extend (c : Candle.t) (trade : Trade.t) : Candle.t =
  { c with
    high = Price.max c.high trade.price
  ; low = Price.min c.low trade.price
  ; close = trade.price
  ; volume = Size.(c.volume + trade.size)
  ; trade_count = c.trade_count + 1
  }
;;

let add t (trade : Trade.t) =
  let open_time = align trade.exch_ts ~interval:t.interval in
  match t.current with
  | None ->
    t.current <- Some (start t ~open_time trade);
    []
  | Some c when Time_ns.( <= ) open_time c.open_time ->
    t.current <- Some (extend c trade);
    []
  | Some c ->
    let rec gaps (prev : Candle.t) acc =
      let next = Time_ns.add prev.open_time t.interval in
      if Time_ns.( >= ) next open_time
      then List.rev acc
      else (
        let e = empty t ~open_time:next ~prev in
        gaps e (e :: acc))
    in
    let completed = c :: gaps c [] in
    t.current <- Some (start t ~open_time trade);
    completed
;;

let of_trades instrument ~interval trades =
  let t = create instrument ~interval in
  let completed = List.concat_map trades ~f:(add t) in
  completed @ Option.to_list t.current
;;
